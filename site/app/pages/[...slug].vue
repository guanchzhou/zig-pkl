<script setup lang="ts">
const route = useRoute()
const { data: page } = await useRepoDoc(route.path)
if (!page.value) {
  throw createError({ statusCode: 404, statusMessage: 'Page not found', fatal: true })
}
</script>

<template>
  <div v-if="page" class="doc-layout">
    <DocNav />
    <article class="prose">
      <ContentRenderer :value="page.doc" />
    </article>
  </div>
</template>
