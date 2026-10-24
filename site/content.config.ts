import { resolve } from 'node:path'
import { defineCollection, defineContentConfig } from '@nuxt/content'

const repo = resolve(__dirname, '..')

function page(dir: string, include: string, prefix: string) {
  return defineCollection({
    type: 'page',
    source: { cwd: resolve(repo, dir), include, prefix },
  })
}

export default defineContentConfig({
  collections: {
    guides: page('docs/guides', '*.md', '/guides'),
    reference: page('docs', 'codegen.md', '/'),
    benchmarks: page('docs/benchmarks', '*.md', '/benchmarks'),
    changelog: page('.', 'CHANGELOG.md', '/'),
  },
})
