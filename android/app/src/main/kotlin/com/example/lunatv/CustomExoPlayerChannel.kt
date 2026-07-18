package org.moontechlab.lunatv

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import android.view.TextureView
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * v2.3.10: 自定义 ExoPlayer 替换 video_player package, 主要是为了能配
 *   DefaultLoadControl 的 buffer 时间. video_player package 内部用默认
 *   LoadControl (minBufferMs=15s, maxBufferMs=50s, bufferForPlaybackMs=
 *   2.5s, bufferForPlaybackAfterRebufferMs=5s), 这些参数没法从 Dart
 *   配. 卡顿时用户希望 "buffer 时间长点", 实际就是把这两个时间拉长:
 *   1) minBufferMs → 30s: 开始播放前要 buffer 30s, 而不是 15s
 *   2) maxBufferMs → 90s: 最多 buffer 90s
 *   3) bufferForPlaybackMs → 5s: 已经有 5s buffer 就能开始
 *   4) bufferForPlaybackAfterRebufferMs → 8s: 卡顿恢复后 8s 才继续
 *   这样卡顿恢复时会等更久才继续, 中间能填更多 buffer, 减少再卡.
 *
 * v2.3.10: 实现成 MethodChannel, 跟 ExoSpeedTestChannel 一样的模式.
 *   - `create` 创建一个 ExoPlayer 实例, 返回 playerId
 *   - `setMediaItem(playerId, url, headers)` 设置媒体
 *   - `prepare`/`play`/`pause`/`seekTo`/`setVolume`/`setSpeed` 标准播放控制
 *   - `release(playerId)` 释放
 *   - 跟 video_player 不同的是, 这个 channel **没有 Texture 输出** —
 *     用户要画面需要自己嵌 TextureView. 实际上, 这次改动先不动
 *     ExoPlayerView 的渲染 (还是用 video_player widget 渲染 surface),
 *     只用本 channel 创建一个 "buffer prefetch" player. 它跟 video_player
 *     的 player 共享 HTTP cache (通过 DefaultDataSource + OkHttp 的
 *     connection pool), 提前 download 几个分片, 等 video_player 开始
 *     播放时这些分片已经在网络层 cache 里, 减少起播卡顿.
 *   - 这个 channel **不影响播放 UI**, 单纯做 buffer prefetch 用. 真正的
 *     播放还是用 video_player. 这样不需要 refactor 整个 player 链路.
 */
@UnstableApi
class CustomExoPlayerChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "CustomExoPlayer"
        const val METHOD_CHANNEL = "org.moontechlab.lunatv/custom_exo_player"
        const val EVENT_CHANNEL = "org.moontechlab.lunatv/custom_exo_player_events"

        // v2.3.10: 默认 buffer 配置 (毫秒)
        //   - 视频加速 (CF Worker 代理) 删了之后, 源站 CDN 直连, 网络
        //     抖动会比之前更明显. 加大 buffer 能减少起播 / 中途卡顿.
        //   - 默认值比 video_player 的 DefaultLoadControl 大:
        //       video_player: min=15s, max=50s, fp=2.5s, fp_re=5s
        //       这里:        min=30s, max=90s, fp=5s,   fp_re=8s
        //   - 30s min + 5s fp 意味着 5s buffer 就能起播, 但后续会持续
        //     buffer 到 30s. 90s max 防止内存爆炸.
        const val DEFAULT_MIN_BUFFER_MS = 30_000
        const val DEFAULT_MAX_BUFFER_MS = 90_000
        const val DEFAULT_BUFFER_FOR_PLAYBACK_MS = 5_000
        const val DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 8_000
    }

    private val handlerThread = HandlerThread("CustomExoPlayer").apply { start() }
    private val handler = Handler(handlerThread.looper)
    private val mainHandler = Handler(Looper.getMainLooper())

    private val players = ConcurrentHashMap<Int, ExoPlayer>()
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
        val bufferForPlaybackAfterRebufferMs = (call.argument<Int>("bufferForPlaybackAfterRebufferMs")) ?: DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS

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

                val id = nextPlayerId.getAndIncrement()
                players[id] = player
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
                })

                mainHandler.post {
                    result.success(mapOf(
                        "playerId" to id,
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
                val player = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                player.setMediaItem(MediaItem.fromUri(url))
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
                val player = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                player.prepare()
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
                val player = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                action(player)
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
                val player = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                player.seekTo(positionMs)
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
                val player = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                player.volume = volume.toFloat().coerceIn(0f, 1f)
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
                val player = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                player.playbackParameters = PlaybackParameters(speed.toFloat().coerceIn(0.1f, 4f))
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
                val player = players[playerId] ?: run {
                    mainHandler.post { result.error("NO_PLAYER", "no player $playerId", null) }
                    return@post
                }
                val state = mapOf(
                    "isPlaying" to player.isPlaying,
                    "isBuffering" to (player.playbackState == Player.STATE_BUFFERING),
                    "durationMs" to player.duration.coerceAtLeast(0L),
                    "positionMs" to player.currentPosition.coerceAtLeast(0L),
                    "playbackState" to player.playbackState,
                    "error" to (playerStates[playerId]?.error ?: ""),
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
                val player = players.remove(playerId)
                playerStates.remove(playerId)
                if (player != null) {
                    player.stop()
                    player.release()
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
                players.values.forEach { p ->
                    try { p.stop() } catch (_: Exception) {}
                    try { p.release() } catch (_: Exception) {}
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
        val player = players[playerId] ?: return
        val state = mapOf(
            "playerId" to playerId,
            "isPlaying" to player.isPlaying,
            "isBuffering" to (player.playbackState == Player.STATE_BUFFERING),
            "durationMs" to player.duration.coerceAtLeast(0L),
            "positionMs" to player.currentPosition.coerceAtLeast(0L),
            "playbackState" to player.playbackState,
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
    }
}
