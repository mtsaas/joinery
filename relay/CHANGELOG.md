# Changelog

## [0.3.0](https://github.com/mtsaas/joinery/compare/relay-v0.2.1...relay-v0.3.0) (2026-10-31)


### Features

* presence over UDP beside each WebSocket, and the relay's two benchmarks ([#22](https://github.com/mtsaas/joinery/issues/22)) ([658b768](https://github.com/mtsaas/joinery/commit/658b768f2a9e9536bd8835bab2b53c1d39351e9b))

## [0.2.1](https://github.com/mtsaas/joinery/compare/relay-v0.2.0...relay-v0.2.1) (2026-10-30)


### Bug Fixes

* a ring buffer for each connection's outbox, so a slow reader can't make queueing cost what's queued ([#7](https://github.com/mtsaas/joinery/issues/7)) ([c1c7155](https://github.com/mtsaas/joinery/commit/c1c71551eebc3b731e9723726e943566554e25c2))
* cap public connections below the descriptor limit, so a flood can't starve the liveness probe ([#9](https://github.com/mtsaas/joinery/issues/9)) ([2b269e4](https://github.com/mtsaas/joinery/commit/2b269e41faa366b843bcb905888a6e8c9c650344))
* cap rooms and connections, so anonymous hosts can't exhaust the relay's memory ([#11](https://github.com/mtsaas/joinery/issues/11)) ([7c81114](https://github.com/mtsaas/joinery/commit/7c811142f4f688623c335573f3164959c914418c))
* cap what the relay's outboxes hold, so non-readers can't exhaust its memory ([#8](https://github.com/mtsaas/joinery/issues/8)) ([d1ced14](https://github.com/mtsaas/joinery/commit/d1ced1433ab14dd673fbfd2fa3036c9baa68eaf0))
* drop a host whose seq leaves no room for the next, instead of crashing the relay ([#4](https://github.com/mtsaas/joinery/issues/4)) ([8fda54d](https://github.com/mtsaas/joinery/commit/8fda54d0ca3d72e850cd026dd20b7bd1102f9912))
* give a lagging connection's outbox back at once, and check the budget on handover ([#13](https://github.com/mtsaas/joinery/issues/13)) ([7c544a3](https://github.com/mtsaas/joinery/commit/7c544a397950e348ead9540b7112c9006711fb4f))
* tell the relay once of each connection it lets go, and assert what it relies on ([#6](https://github.com/mtsaas/joinery/issues/6)) ([0e261b6](https://github.com/mtsaas/joinery/commit/0e261b67d45320d34bac87e5d8e1154a15b46b67))

## [0.2.0](https://github.com/mtsaas/joinery/compare/relay-v0.1.0...relay-v0.2.0) (2026-10-29)


### Features

* **relay:** container image and Helm chart ([211157f](https://github.com/mtsaas/joinery/commit/211157ff9113614d550f82c118483fc1793887da))
