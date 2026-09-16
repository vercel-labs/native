// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  compatibilityDate: '2026-05-11',
  ssr: true,
  devtools: { enabled: true },
  routeRules: {
    // '/': { prerender: true },
    // can use glob patterns to prerender multiple routes
    '/**': { prerender: true },
  },
  nitro: {
    preset: 'static',
  },
})
