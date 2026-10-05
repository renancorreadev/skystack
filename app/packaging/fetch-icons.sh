#!/usr/bin/env bash
# Downloads real brand logos for common container technologies and rasterizes
# them to PNG, bundled into the app so icons render offline (no per-container
# network calls at runtime). Sources: devicon (MIT) and iconify "logos" (CC0).
# Re-run any time to refresh; it's idempotent.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../Sources/SkyStackApp/Resources/brand-icons"
SIZE=128
mkdir -p "$OUT"

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert (brew install librsvg)"; exit 1; }

DEVICON="https://raw.githubusercontent.com/devicons/devicon/master/icons"
ICONIFY="https://api.iconify.design"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ok=0; miss=0

# Try to fetch an SVG into $1 from a URL $2; returns 0 if it looks like SVG.
get_svg() {
  local dest="$1" url="$2"
  curl -fsSL "$url" -o "$dest" 2>/dev/null || return 1
  head -c 64 "$dest" | grep -qi 'svg\|<?xml' || return 1
  return 0
}

# emit <key> <devicon-dir> [iconify-logos-name]
emit() {
  local key="$1" dir="$2" logos="${3:-}"
  local svg="$tmp/$key.svg" got=1
  for v in original original-wordmark plain plain-wordmark; do
    if get_svg "$svg" "$DEVICON/$dir/$dir-$v.svg"; then got=0; break; fi
  done
  if [ $got -ne 0 ] && [ -n "$logos" ]; then
    get_svg "$svg" "$ICONIFY/logos/$logos.svg" && got=0
  fi
  if [ $got -ne 0 ]; then echo "  miss $key"; miss=$((miss+1)); return; fi
  if rsvg-convert -h "$SIZE" "$svg" -o "$OUT/$key.png" 2>/dev/null; then
    ok=$((ok+1))
  else echo "  conv-fail $key"; miss=$((miss+1)); fi
}

# key            devicon-dir      iconify-logos-fallback
emit go            go              go
emit nodejs        nodejs          nodejs-icon
emit react         react           react
emit vue           vuejs           vue
emit angular       angular         angular-icon
emit nestjs        nestjs          nestjs
emit nextjs        nextjs          nextjs-icon
emit svelte        svelte          svelte-icon
emit python        python          python
emit django        django         django-icon
emit flask         flask           flask
emit ruby          ruby            ruby
emit rails         rails           rails
emit spring        spring          spring-icon
emit java          java            java
emit php           php             php
emit laravel       laravel         laravel
emit dotnet        dotnetcore      dotnet
emit rust          rust            rust
emit elixir        elixir          elixir
emit deno          denojs          deno
emit bun           bun             bun
emit postgresql    postgresql      postgresql
emit mysql         mysql           mysql-icon
emit mariadb       mariadb         mariadb-icon
emit mongodb       mongodb         mongodb-icon
emit redis         redis           redis
emit rabbitmq      rabbitmq        rabbitmq-icon
emit kafka         apachekafka     kafka-icon
emit nats          ""              nats-icon
emit elasticsearch elasticsearch   elasticsearch
emit nginx         nginx           nginx
emit apache        apache          ""
emit traefik       traefikproxy    traefik
emit kong          ""              kong-icon
emit grafana       grafana         grafana
emit prometheus    prometheus      prometheus
emit minio         ""              minio
emit vault         ""              vault-icon
emit consul        ""              consul-icon
emit kubernetes    kubernetes      kubernetes
emit docker        docker          docker-icon
emit ethereum      ""              ethereum
emit golang        go              go

echo "icons: $ok ok, $miss missing → $OUT"
