package org.moontechlab.lunatv

import android.content.Context
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * v2.3.11: 自定义 ExoPlayer 替换 video_player package, 主要是为了能配
 *   DefaultLoadControl 的 buffer 时间 + 自己拥有 Surface 输出 (Texture).
 *
 *   video_player package 的问题:
 *   - 内部 DefaultLoadControl (minBufferMs=15s, maxBufferMs=50s,
 *     bufferForPlaybackMs=2.5s, bufferForPlaybackAfterRebufferMs=5s)
 *     Dart 端无法配. 卡顿时频繁 rebuffer.
 *   - Surface 输出走它自己的 Media3 PlayerView, 没法嵌进 Flutter Texture.
 *
 *   改用本 channel:
 *   - 1) [DefaultLoadControl] 自定义: min=30s, max=90s, fp=5s, fp_re=8s
 *        起播需 5s buffer, 持续填到 30s 才允许"全速播放", 卡顿恢复后
 *        等 8s 再继续 (中间能填更多 buffer, 减少再卡).
 *   - 2) [TextureRegistry] 创建 SurfaceTexture, wrap 成 [Surface] 挂给
 *        ExoPlayer. Dart 端用 [Texture] widget 渲染. 这样 ExoPlayer 完全
 *        在 Flutter 渲染树外, 但视频帧通过 GPU texture 0 copy 显示.
 *
 *   API:
 *   - `create` 创建一个 ExoPlayer 实例 + texture, 返回 { playerId, textureId }
 *   - `setMediaItem`/`prepare`/`play`/`pause`/`seekTo`/`setVolume`/`setSpeed`
 *   - `release(playerId)` 释放 player + texture
 *   - `releaseAll` 全部释放
 *   - EventChannel 推 { playerId, isPlaying, isBuffering, durationMs,
 *     positionMs, playbackState, videoSize, videoWidth, videoHeight }
 *     (v2.3.11 新增 videoWidth/videoHeight 替代 video_player 渲染同步)
 *
 *   v2.3.10 这个 channel 已经存在但没 texture 输出, 当时只作为 building
 *   block. v2.3.11 真正替换 video_player.
 */
@UnstableApi
class CustomExoPlayerChannel(
    private val context: Context,
    private val flutterEngine: FlutterEngine,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "CustomExoPlayer"
        const val METHOD_CHANNEL = "org.moontechlab.lunatv/custom_exo_player"
        const val EVENT_CHANNEL = "org.moontechlab.lunatv/custom_exo_player_events"

        // v2.3.10 / v2.3.11 默认 buffer 配置 (毫秒)
        //   - 比 video_player 的 DefaultLoadControl 大:
        //       video_player: min=15s, max=50s, fp=2.5s, fp_re=5s
        //       这里:        min=30s, max=90s, fp=5s,   fp_re=8s
        //   - 30s min + 5s fp 意味着 5s buffer 就能起播, 但后续会持续
        //     buffer 到 30s. 90s max 防止内存爆炸.
        const val DEFAULT_MIN_BUFFER_MS = 30_000
        const val DEFAULT_MAX_BUFFER_MS = 90_000
        const val DEFAULT_BUFFER_FOR_PLAYBACK_MS = 5_000
        const val DEFAULT_BUFFER_FOR_REBUFFER_MS = 8_000
    }

    private val handlerThread = HandlerThread("CustomExoPlayer").apply { start() }
    private val handler = Handler(handlerThread.looper)
    private val mainHandler = Handler(Looper.getMainLooper())

    // v2.3.11: 每个 player 关联一个 SurfaceTextureEntry (Flutter 端 texture)
    //   release player 时同时 release texture entry, 否则 Flutter 端的
    //   texture ID 会泄漏, 下次 create 拿到一个已失效的 ID.
    private data class PlayerBundle(
        val player: ExoPlayer,
        val textureEntry: TextureRegistry.SurfaceTextureEntry?,
    )

    private val players = ConcurrentHashMap<Int, PlayerBundle>()
    private val playerStates = ConcurrentHashMap<Int, PlayerState>()
    private val nextPlayerId = AtomicInteger(1)

    private val eventSinkRef = java.util.concurrent.atomic.AtomicReference<EventChannel.EventSink?>(null)

    init {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSinkRef.set(events)
            }
            override fun onCancel(arguments: Any?) {
                eventSinkRef.set(null)
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> handleCreate(call, result)
            "setMediaItem" -> handleSetMediaItem(call, result)
            "prepare" -> handlePrepare(call, result)
            "play" -> handleSimple(call, result, "play") { it.play() }
            "pause" -> handleSimple(call, result, "pause") { it.pause() }
            "stop" -> handleSimple(call, result, "stop") { it.stop() }
            "seekTo" -> handleSeekTo(call, result)
            "setVolume" -> handleSetVolume(call, result)
            "setSpeed" -> handleSetSpeed(call, result)
            "getState" -> handleGetState(call, result)
            "release" -> handleRelease(call, result)
            "releaseAll" -> handleReleaseAll(result)
            else -> result.notImplemented()
        }
    }

    private fun handleCreate(call: MethodCall, result: MethodChannel.Result) {
        val minBufferMs = (call.argument<Int>("minBufferMs")) ?: DEFAULT_MIN_BUFFER_MS
        val maxBufferMs = (call.argument<Int>("maxBufferMs")) ?: DEFAULT_MAX_BUFFER_MS
        val bufferForPlaybackMs = (call.argument<Int>("bufferForPlaybackMs")) ?: DEFAULT_BUFFER_FOR_PLAYBACK_MS
        val bufferForPlaybackAfterRebufferMs = (call.argument<Int>("bufferForPlaybackAfterRebufferMs")) ?: DEFAULT_BUFFER_FOR_REBUFFER_MS
        val wantTexture = call.argument<Boolean>("withTexture") ?: true

        handler.post {
            try {
                val loadControl = DefaultLoadControl.Builder()
                    .setBufferDurationsMs(
                        minBufferMs,
                        maxBufferMs,
                        bufferForPlaybackMs,
                        bufferForPlaybackAfterRebufferMs
                    )
                    .build()

                val httpFactory = DefaultHttpDataSource.Factory()
                    .setUserAgent("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
                    .setConnectTimeoutMs(8000)
                    .setReadTimeoutMs(15000)
                    .setAllowCrossProtocolRedirects(true)
                val dataSourceFactory = DefaultDataSource.Factory(context, httpFactory)
                val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)

                val player = ExoPlayer.Builder(context)
                    .setLoadControl(loadControl)
                    .setMediaSourceFactory(mediaSourceFactory)
                    .build()

                // v2.3.11: 创建 Flutter texture + attach surface 到 ExoPlayer
                val textureEntry: TextureRegistry.SurfaceTextureEntry? = if (wantTexture) {
                    val entry = flutterEngine.renderer.createSurfaceTexture()
                    val surfaceTexture: SurfaceTexture = entry.surfaceTexture()
                    // v2.3.11: 把 SurfaceTexture 默认 buffer size 设成 0 (0=auto)
                    //   SurfaceTexture 默认 buffer size 是 width/height, ExoPlayer
                    //   内部按视频分辨率写, 跟 SurfaceTexture 默认 size 不一定一致,
                    //   视频尺寸变化时不更新会变形. setDefaultBufferSize(0,0) 让
                    //   SurfaceTexture 跟着 input size 走 (BufferSize 跟 size 走).
                    //   实际测试下来这样写最稳: 720p / 1080p 切换, 4:3 / 16:9
                    //   切换都不会变形.
                    surfaceTexture.setDefaultBufferSize(0, 0)
                    val surface = Surface(surfaceTexture)
                    player.setVideoSurface(surface)
                    entry
                } else {
                    null
                }

                val id = nextPlayerId.getAndIncrement()
                players[id] = PlayerBundle(player, textureEntry)
                playerStates[id] = PlayerState()

                player.addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(playbackState: Int) {
                        val st = playerStates[id] ?: return
                        st.playbackState = playbackState
                        st.isBuffering = playbackState == Player.STATE_BUFFERING
                        emitState(id)
                    }
                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        val st = playerStates[id] ?: return
                        st.isPlaying = isPlaying
                        emitState(id)
                    }
                    override fun onPlayerError(error: PlaybackException) {
                        val st = playerStates[id] ?: return
                        st.error = "${error.errorCode}: ${error.message}"
                        emitState(id)
                    }
                    override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                        val st = playerStates[id] ?: return
                        st.videoWidth = videoSize.width
                        st.videoHeight = videoSize.height
                        emitState(id)
                    }
                })

                mainHandler.post {
                    result.success(mapOf(
                        "playerId" to id,
                        "textureId" to textureEntry?.id(),
                        "minBufferMs" to minBufferMs,
                        "maxBufferMs" to maxBufferMs,
                        "bufferForPlaybackMs" to bufferForPlaybackMs,
                        "bufferForPlaybackAfterRebufferMs" to bufferForPlaybackAfterRebufferMs,
                    ))
                }
            } catch (e: Exception) {
                Log.e(TAG, "create failed", e)
                mainHandler.post { result.error("CREATE_FAILED", e.message, null) }
            }
        }
    }

    private fun handleSetMediaItem(call: MethodCall, result: MethodChannel.Result) {
        val playerId = call.argument<Int>("playerId") ?: -1
        val url = call.argument<String>("url")
        if (playerId <= 0 || url.isNullOrEmpty()) {
            result.error("INVALID_ARG", "playerId and url required", null)
            return
        }
        handler.post {
            try {
                val bundle = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                bundle.player.setMediaItem(MediaItem.fromUri(url))
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("SET_MEDIA_FAILED", e.message, null) }
            }
        }
    }

    private fun handlePrepare(call: MethodCall, result: MethodChannel.Result) {
        val playerId = call.argument<Int>("playerId") ?: -1
        handler.post {
            try {
                val bundle = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                bundle.player.prepare()
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("PREPARE_FAILED", e.message, null) }
            }
        }
    }

    private fun handleSimple(call: MethodCall, result: MethodChannel.Result, name: String, action: (ExoPlayer) -> Unit) {
        val playerId = call.argument<Int>("playerId") ?: -1
        handler.post {
            try {
                val bundle = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                action(bundle.player)
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("${name.uppercase()}_FAILED", e.message, null) }
            }
        }
    }

    private fun handleSeekTo(call: MethodCall, result: MethodChannel.Result) {
        val playerId = call.argument<Int>("playerId") ?: -1
        val positionMs = (call.argument<Number>("positionMs"))?.toLong() ?: 0L
        handler.post {
            try {
                val bundle = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                bundle.player.seekTo(positionMs)
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("SEEK_FAILED", e.message, null) }
            }
        }
    }

    private fun handleSetVolume(call: MethodCall, result: MethodChannel.Result) {
        val playerId = call.argument<Int>("playerId") ?: -1
        val volume = (call.argument<Number>("volume"))?.toDouble() ?: 1.0
        handler.post {
            try {
                val bundle = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                bundle.player.volume = volume.toFloat().coerceIn(0f, 1f)
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("SET_VOLUME_FAILED", e.message, null) }
            }
        }
    }

    private fun handleSetSpeed(call: MethodCall, result: MethodChannel.Result) {
        val playerId = call.argument<Int>("playerId") ?: -1
        val speed = (call.argument<Number>("speed"))?.toDouble() ?: 1.0
        handler.post {
            try {
                val bundle = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                bundle.player.playbackParameters = PlaybackParameters(speed.toFloat().coerceIn(0.1f, 4f))
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("SET_SPEED_FAILED", e.message, null) }
            }
        }
    }

    private fun handleGetState(call: MethodCall, result: MethodChannel.Result) {
        val playerId = call.argument<Int>("playerId") ?: -1
        handler.post {
            try {
                val bundle = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                val p = bundle.player
                val st = playerStates[playerId]
                val state = mapOf(
                    "isPlaying" to p.isPlaying,
                    "isBuffering" to (p.playbackState == Player.STATE_BUFFERING),
                    "durationMs" to p.duration.coerceAtLeast(0L),
                    "positionMs" to p.currentPosition.coerceAtLeast(0L),
                    "playbackState" to p.playbackState,
                    "videoWidth" to (st?.videoWidth ?: 0),
                    "videoHeight" to (st?.videoHeight ?: 0),
                    "error" to (st?.error ?: ""),
                )
                mainHandler.post { result.success(state) }
            } catch (e: Exception) {
                mainHandler.post { result.error("GET_STATE_FAILED", e.message, null) }
            }
        }
    }

    private fun handleRelease(call: MethodCall, result: MethodChannel.Result) {
        val playerId = call.argument<Int>("playerId") ?: -1
        handler.post {
            try {
                val bundle = players.remove(playerId)
                playerStates.remove(playerId)
                if (bundle != null) {
                    try { bundle.player.stop() } catch (_: Exception) {}
                    try { bundle.player.release() } catch (_: Exception) {}
                    // v2.3.11: 释放 texture entry, Flutter 端 texture ID 失效
                    try { bundle.textureEntry?.release() } catch (_: Exception) {}
                }
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("RELEASE_FAILED", e.message, null) }
            }
        }
    }

    private fun handleReleaseAll(result: MethodChannel.Result) {
        handler.post {
            try {
                players.values.forEach { b ->
                    try { b.player.stop() } catch (_: Exception) {}
                    try { b.player.release() } catch (_: Exception) {}
                    try { b.textureEntry?.release() } catch (_: Exception) {}
                }
                players.clear()
                playerStates.clear()
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("RELEASE_ALL_FAILED", e.message, null) }
            }
        }
    }

    private fun emitState(playerId: Int) {
        val bundle = players[playerId] ?: return
        val st = playerStates[playerId] ?: return
        val p = bundle.player
        val state = mapOf(
            "playerId" to playerId,
            "isPlaying" to p.isPlaying,
            "isBuffering" to (p.playbackState == Player.STATE_BUFFERING),
            "durationMs" to p.duration.coerceAtLeast(0L),
            "positionMs" to p.currentPosition.coerceAtLeast(0L),
            "playbackState" to p.playbackState,
            "videoWidth" to st.videoWidth,
            "videoHeight" to st.videoHeight,
        )
        val sink = eventSinkRef.get() ?: return
        mainHandler.post {
            try { sink.success(state) } catch (_: Exception) {}
        }
    }

    private class PlayerState {
        var playbackState: Int = Player.STATE_IDLE
        var isPlaying: Boolean = false
        var isBuffering: Boolean = false
        var error: String = ""
        var videoWidth: Int = 0
        var videoHeight: Int = 0
    }
}
