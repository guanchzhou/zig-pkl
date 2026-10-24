import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const apiDocs = process.env.ZIG_PKL_API_DOCS
  ? resolve(process.env.ZIG_PKL_API_DOCS)
  : fileURLToPath(new URL('../zig-out/docs', import.meta.url))

export default defineNuxtConfig({
  compatibilityDate: '2026-10-01',
  modules: ['@nuxt/content'],
  css: ['~/assets/css/main.css'],
  app: {
    head: {
      htmlAttrs: { lang: 'en' },
      title: 'zig-pkl',
      meta: [{ name: 'description', content: 'Zig 0.17 bindings for Pkl' }],
    },
  },
  content: {
    experimental: { sqliteConnector: 'native' },
    build: {
      markdown: {
        highlight: {
          theme: { default: 'github-light', dark: 'github-dark' },
          langs: ['zig', 'pkl', 'shellscript', 'json', 'yaml'],
        },
      },
    },
  },
  nitro: {
    publicAssets: existsSync(apiDocs) ? [{ dir: apiDocs, baseURL: '/api' }] : [],
    prerender: {
      crawlLinks: true,
      routes: ['/'],
      ignore: [/\/api(\/|$)/],
    },
  },
  vite: {
    server: { fs: { allow: ['..'] } },
  },
})
