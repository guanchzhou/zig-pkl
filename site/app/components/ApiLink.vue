<script setup lang="ts">
const href = `${useRuntimeConfig().app.baseURL}api/`
</script>

<template>
  <a :href="href"><slot /></a>
</template>
