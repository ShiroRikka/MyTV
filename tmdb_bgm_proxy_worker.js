// TMDB + Bangumi 统一代理 Worker (在原 tmdb-proxy 基础上扩展)
// 路由:
//   /movie/..., /tv/..., /search/...  → TMDB API  (api.themoviedb.org/3)
//   /image/...                        → TMDB 图片 (image.tmdb.org)
//   /bangumi/...                      → Bangumi API (api.bgm.tv), 透传客户端 Authorization
//   /bgm-img/...                      → Bangumi 图片 (lain.bgm.tv), 自动补 Referer
// 环境变量 (在 Cloudflare Dashboard / wrangler secret 配):
//   TMDB_API_KEY       必需  TMDB API key
//   BGM_ACCESS_TOKEN   可选  Bangumi access_token, 缺省时透传客户端 Authorization header

export default {
  async fetch(request, env, ctx) {
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, HEAD, POST, OPTIONS',
      'Access-Control-Allow-Headers': '*',
    }
    // 预检请求
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders })
    }
    try {
      const url = new URL(request.url)

      // Bangumi 图片代理 (优先匹配, 避免和 /image 冲突)
      if (url.pathname.startsWith('/bgm-img/')) {
        return await handleBgmImage(request, url, corsHeaders)
      }

      // Bangumi API 代理
      if (url.pathname.startsWith('/bangumi/')) {
        return await handleBgmApi(request, url, env, corsHeaders)
      }

      // TMDB 图片代理
      if (url.pathname.startsWith('/image/')) {
        return await handleTmdbImage(request, url, corsHeaders)
      }

      // 兜底: TMDB API 代理
      return await handleTmdbApi(request, url, env, corsHeaders)
    } catch (error) {
      return new Response(JSON.stringify({
        error: 'Proxy error',
        message: error.message
      }), {
        status: 500,
        headers: { 'Content-Type': 'application/json', ...corsHeaders }
      })
    }
  }
}

// ===== TMDB 图片代理 (image.tmdb.org) =====
async function handleTmdbImage(request, url, corsHeaders) {
  // 格式: /image/t/p/w500/abc.jpg 或 /image/w500/abc.jpg
  const imagePath = url.pathname.replace('/image', '')
  if (!imagePath) {
    return jsonError('Image path required', 400, corsHeaders)
  }
  const imageUrl = `https://image.tmdb.org${imagePath}`
  const response = await fetch(imageUrl)
  if (!response.ok) {
    return jsonError('Image not found', response.status, corsHeaders, { url: imageUrl })
  }
  const contentType = response.headers.get('content-type') || 'image/jpeg'
  const buf = await response.arrayBuffer()
  return new Response(buf, {
    status: response.status,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=86400', // 缓存 1 天
      ...corsHeaders,
    }
  })
}

// ===== TMDB API 代理 (api.themoviedb.org/3) =====
async function handleTmdbApi(request, url, env, corsHeaders) {
  let apiPath = url.pathname
  // 兼容旧版 /proxy 前缀
  if (apiPath.startsWith('/proxy')) {
    apiPath = apiPath.replace('/proxy', '')
  }
  const searchParams = new URLSearchParams(url.searchParams)
  if (env.TMDB_API_KEY) {
    searchParams.set('api_key', env.TMDB_API_KEY)
  } else {
    return jsonError('TMDB API key not configured', 500, corsHeaders)
  }
  const apiUrl = `https://api.themoviedb.org/3${apiPath}?${searchParams}`
  const response = await fetch(apiUrl, {
    method: request.method,
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    }
  })
  return withCors(response, corsHeaders)
}

// ===== Bangumi API 代理 (api.bgm.tv) =====
// 透传客户端 Authorization (如果有), 否则尝试用 env.BGM_ACCESS_TOKEN.
// 强制 UA 满足 api.bgm.tv v0 API 的 "App/Version (URL)" 格式要求.
async function handleBgmApi(request, url, env, corsHeaders) {
  // /bangumi/v0/subject/123  →  https://api.bgm.tv/v0/subject/123
  const apiPath = url.pathname.replace('/bangumi', '')
  const searchParams = new URLSearchParams(url.searchParams)
  const apiUrl = `https://api.bgm.tv${apiPath}?${searchParams}`

  const headers = new Headers(request.headers)
  // 强制 UA: api.bgm.tv 拒绝浏览器 UA (返 400)
  if (!headers.has('User-Agent')) {
    headers.set('User-Agent', 'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)')
  }
  // 服务端持有 access_token 时, 注入 Bearer (缺省透传客户端)
  if (env.BGM_ACCESS_TOKEN && !headers.has('Authorization')) {
    headers.set('Authorization', `Bearer ${env.BGM_ACCESS_TOKEN}`)
  }
  // 透传方法, body 也透传
  const init = {
    method: request.method,
    headers,
  }
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    init.body = await request.arrayBuffer()
  }

  const response = await fetch(apiUrl, init)
  return withCors(response, corsHeaders)
}

// ===== Bangumi 图片代理 (lain.bgm.tv) =====
// lain.bgm.tv 校验 Referer, 必须带 https://bgm.tv/
async function handleBgmImage(request, url, corsHeaders) {
  // /bgm-img/r/400/.../abc.jpg  →  https://lain.bgm.tv/r/400/.../abc.jpg
  const imagePath = url.pathname.replace('/bgm-img', '')
  if (!imagePath) {
    return jsonError('Image path required', 400, corsHeaders)
  }
  const imageUrl = `https://lain.bgm.tv${imagePath}`
  const response = await fetch(imageUrl, {
    headers: {
      'Referer': 'https://bgm.tv/',
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    }
  })
  if (!response.ok) {
    return jsonError('Image not found', response.status, corsHeaders, { url: imageUrl })
  }
  const contentType = response.headers.get('content-type') || 'image/jpeg'
  const buf = await response.arrayBuffer()
  return new Response(buf, {
    status: response.status,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=86400', // 缓存 1 天
      ...corsHeaders,
    }
  })
}

// ===== 工具函数 =====
function withCors(response, corsHeaders) {
  const modified = new Response(response.body, response)
  for (const [k, v] of Object.entries(corsHeaders)) {
    modified.headers.set(k, v)
  }
  return modified
}

function jsonError(error, status, corsHeaders, extra = {}) {
  return new Response(JSON.stringify({ error, ...extra }), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders }
  })
}
