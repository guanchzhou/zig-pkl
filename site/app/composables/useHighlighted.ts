export interface CodeInput {
  code: string
  lang: string
}

/** Highlights code during prerendering; the HTML reaches the browser in the page payload. */
export function useHighlighted(key: string, blocks: CodeInput[]) {
  return useAsyncData(`highlight:${key}`, async () => {
    if (!import.meta.server) return blocks.map(() => '')
    const { codeToHtml } = await import('shiki')
    return Promise.all(blocks.map(block => codeToHtml(block.code.replace(/\n$/, ''), {
      lang: block.lang,
      themes: { light: 'github-light', dark: 'github-dark' },
    })))
  })
}
