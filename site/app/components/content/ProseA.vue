<script setup lang="ts">
import type { Ref } from 'vue'

const props = defineProps<{ href?: string, target?: string }>()
const source = inject<Ref<string>>('docSource', ref(''))
const link = computed(() => resolveRepoLink(props.href ?? '', source.value))
</script>

<template>
  <NuxtLink v-if="link.internal" :to="link.to"><slot /></NuxtLink>
  <a v-else :href="link.to" :target="target"><slot /></a>
</template>
