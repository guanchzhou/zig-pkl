<script setup lang="ts">
defineProps<{ html: string }>()
</script>

<template>
  <div class="code-block" v-html="html" />
</template>
