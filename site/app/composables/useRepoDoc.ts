/** Loads the repository Markdown page served at `path` and exposes its file path to `ProseA`. */
export function useRepoDoc(path: string) {
  const result = useAsyncData(`doc:${path}`, async () => {
    for (const collection of docCollections) {
      const doc = await queryCollection(collection.name).path(path).first()
      if (doc) {
        const file = `${doc.stem.split('/').pop()}.${doc.extension}`
        return { doc, source: collection.dir ? `${collection.dir}/${file}` : file }
      }
    }
    return null
  })
  provide('docSource', computed(() => result.data.value?.source ?? ''))
  useSeoMeta({
    title: () => (result.data.value ? `${result.data.value.doc.title} | zig-pkl` : 'zig-pkl'),
    description: () => result.data.value?.doc.description,
  })
  return result
}
