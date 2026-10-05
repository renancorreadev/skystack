import SwiftUI

// serviceVisual maps a container image to a tasteful icon + color. It's a curated,
// offline lookup (no network/logo fetching) keyed on the image name, with a
// deterministic colored fallback so every unknown service still looks distinct.
func serviceVisual(image: String, name: String) -> (symbol: String, color: Color) {
    if let v = visualByImage(image.lowercased()) { return v }
    if let v = visualByName(name.lowercased()) { return v }
    return ("shippingbox.fill", hashedColor(name.isEmpty ? image : name))
}

// visualByImage matches well-known product images. Tokens are precise (e.g.
// "besu:"/"hyperledger/besu", not bare "besu") so "besuscan" doesn't false-match.
private func visualByImage(_ img: String) -> (symbol: String, color: Color)? {
    func has(_ keys: String...) -> Bool { keys.contains { img.contains($0) } }

    switch true {
    // Databases
    case has("postgres", "pgvector"):            return ("cylinder.split.1x2.fill", .blue)
    case has("mysql", "mariadb", "percona"):     return ("cylinder.split.1x2.fill", .orange)
    case has("mongo"):                            return ("leaf.fill", .green)
    case has("cockroach"):                        return ("cylinder.split.1x2.fill", .teal)
    case has("questdb", "influx", "timescale"):  return ("chart.xyaxis.line", .indigo)
    case has("clickhouse"):                       return ("chart.bar.fill", .yellow)
    // Caches / KV
    case has("redis", "valkey", "keydb"):        return ("bolt.fill", .red)
    case has("memcached"):                         return ("bolt.fill", .gray)
    case has("etcd", "consul"):                    return ("key.fill", .pink)
    // Messaging
    case has("rabbitmq"):                          return ("hare.fill", .orange)
    case has("nats"):                              return ("arrow.triangle.branch", .teal)
    case has("kafka", "redpanda"):                 return ("arrow.left.arrow.right", .gray)
    // Search
    case has("elasticsearch", "opensearch"):       return ("magnifyingglass", .yellow)
    case has("meilisearch", "typesense", "solr"):  return ("magnifyingglass", .pink)
    // Web / proxy / gateway
    case has("nginx"):                             return ("globe", .green)
    case has("traefik"):                           return ("arrow.triangle.branch", .cyan)
    case has("haproxy"):                            return ("arrow.triangle.branch", .green)
    case has("caddy"):                             return ("lock.shield.fill", .blue)
    case has("kong"):                              return ("shield.lefthalf.filled", .blue)
    case has("konga"):                             return ("gauge.with.dots.needle.bottom.50percent", .blue)
    case has("envoy"):                             return ("arrow.triangle.branch", .pink)
    case has("varnish"):                           return ("bolt.horizontal.fill", .brown)
    // Runtimes
    case has("node", "nodejs"):                    return ("hexagon.fill", .green)
    case has("python", "django", "flask"):         return ("chevron.left.forwardslash.chevron.right", .blue)
    case has("php", "magento", "wordpress"):       return ("chevron.left.forwardslash.chevron.right", .purple)
    case has("golang", "/go:"):                    return ("chevron.left.forwardslash.chevron.right", .cyan)
    case has("ruby", "rails"):                     return ("diamond.fill", .red)
    case has("java", "openjdk", "tomcat"):         return ("cup.and.saucer.fill", .orange)
    // Blockchain (Besu/Ethereum clients) — precise tokens so "besuscan" is excluded
    case has("hyperledger/besu", "besu:", "/besu:", "geth", "client-go", "nethermind", "erigon", "/reth", "reth:", "lighthouse", "prysm"):
        return ("cube.transparent.fill", .purple)
    // Observability
    case has("grafana"):                           return ("chart.bar.xaxis", .orange)
    case has("prometheus"):                         return ("flame.fill", .orange)
    case has("loki", "jaeger", "tempo"):           return ("scope", .pink)
    // Storage / infra
    case has("minio"):                             return ("externaldrive.fill", .red)
    case has("vault"):                             return ("lock.shield.fill", .yellow)
    case has("registry"):                          return ("square.stack.3d.up.fill", .blue)
    case has("metadata"):                          return ("doc.text.magnifyingglass", .teal)
    // Base OS images
    case has("alpine"):                            return ("mountain.2.fill", .blue)
    case has("ubuntu"):                            return ("shippingbox.fill", .orange)
    case has("debian"):                            return ("shippingbox.fill", .red)
    case has("busybox"):                           return ("shippingbox.fill", .gray)
    default:
        return nil
    }
}

// visualByName infers a role from the container/service name for custom-built
// images (e.g. "besuscan-api", "*-frontend", "*-worker") that have no product tag.
private func visualByName(_ name: String) -> (symbol: String, color: Color)? {
    func has(_ keys: String...) -> Bool { keys.contains { name.contains($0) } }
    switch true {
    case has("frontend", "webapp", "-web", "-ui", "dashboard"): return ("macwindow", .green)
    case has("api", "backend", "-svc", "service", "gateway"):   return ("bolt.horizontal.circle.fill", .blue)
    case has("worker", "consumer", "-job"):                     return ("gearshape.2.fill", .orange)
    case has("indexer", "ingest", "crawler"):                   return ("magnifyingglass", .indigo)
    case has("scheduler", "cron", "-beat"):                     return ("clock.fill", .pink)
    case has("migration", "migrate", "seed"):                   return ("arrow.triangle.2.circlepath", .teal)
    case has("proxy", "ingress", "lb"):                         return ("arrow.triangle.branch", .cyan)
    default:
        return nil
    }
}

// A stable color from a string, so unknown services get a consistent distinct hue.
func hashedColor(_ s: String) -> Color {
    let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red, .cyan, .mint, .yellow, .brown]
    var h = 5381
    for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
    return palette[abs(h) % palette.count]
}

// ServiceIcon shows a real bundled brand logo when one matches the image/name,
// otherwise an app-icon-style tinted SF-symbol square. Running = full color;
// stopped = desaturated grey.
struct ServiceIcon: View {
    let image: String
    let name: String
    var running: Bool
    var framework: String? = nil
    var size: CGFloat = 27

    var body: some View {
        if let key = brandKey(image: image, name: name, framework: framework), let logo = BrandIconCache.image(key) {
            Image(nsImage: logo)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .padding(size * 0.06)
                .grayscale(running ? 0 : 0.95)
                .opacity(running ? 1 : 0.5)
        } else {
            symbolFallback
        }
    }

    private var symbolFallback: some View {
        let v = serviceVisual(image: image, name: name)
        let tint = running ? v.color : Color.secondary
        return RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(running ? 0.20 : 0.12))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: v.symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(tint.opacity(running ? 1 : 0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(tint.opacity(running ? 0.25 : 0.12), lineWidth: 0.5)
            )
    }
}

// BrandIconCache lazily loads the bundled brand PNGs (one NSImage per key). It
// locates the SwiftPM resource bundle itself (across `swift run` and the packaged
// .app) instead of using Bundle.module, which fatalErrors when the bundle is
// absent — returning nil lets ServiceIcon fall back to an SF symbol safely.
enum BrandIconCache {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    nonisolated(unsafe) private static var tried: Set<String> = []
    nonisolated(unsafe) private static var dir: URL?
    nonisolated(unsafe) private static var dirSearched = false

    private static func iconsDir() -> URL? {
        if dirSearched { return dir }
        dirSearched = true
        let bundleName = "SkyStackApp_SkyStackApp.bundle"
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(bundleName)) }
        if let e = Bundle.main.executableURL?.deletingLastPathComponent() { candidates.append(e.appendingPathComponent(bundleName)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        let fm = FileManager.default
        for c in candidates {
            let d = c.appendingPathComponent("brand-icons", isDirectory: true)
            if fm.fileExists(atPath: d.path) { dir = d; return d }
        }
        return nil
    }

    static func image(_ key: String) -> NSImage? {
        if let c = cache[key] { return c }
        if tried.contains(key) { return nil }
        tried.insert(key)
        guard let d = iconsDir() else { return nil }
        if let img = NSImage(contentsOf: d.appendingPathComponent("\(key).png")) {
            cache[key] = img
            return img
        }
        return nil
    }
}

// brandKey resolves a container to a bundled brand-logo key (image first, then a
// framework hint from the name), or nil to fall back to an SF symbol.
func brandKey(image: String, name: String, framework: String? = nil) -> String? {
    if let k = brandByImage(image.lowercased()) { return k }
    if let k = brandByName(name.lowercased()) { return k }
    if let f = framework, !f.isEmpty { return f }   // detected framework IS a brand key
    return nil
}

private func brandByImage(_ img: String) -> String? {
    func has(_ keys: String...) -> Bool { keys.contains { img.contains($0) } }
    switch true {
    case has("postgres", "pgvector"):              return "postgresql"
    case has("mysql", "percona"):                  return "mysql"
    case has("mariadb"):                            return "mariadb"
    case has("mongo"):                              return "mongodb"
    case has("redis", "valkey", "keydb"):          return "redis"
    case has("rabbitmq"):                          return "rabbitmq"
    case has("nats"):                              return "nats"
    case has("kafka", "redpanda"):                 return "kafka"
    case has("elasticsearch", "opensearch"):       return "elasticsearch"
    case has("nginx"):                             return "nginx"
    case has("httpd", "/apache"):                  return "apache"
    case has("traefik"):                           return "traefik"
    case has("kong"):                              return "kong"
    case has("grafana"):                           return "grafana"
    case has("prometheus"):                         return "prometheus"
    case has("vault"):                             return "vault"
    case has("k8s", "k3s", "kube"):                return "kubernetes"
    case has("hyperledger/besu", "besu:", "/besu:", "geth", "client-go", "nethermind", "erigon", "/reth", "reth:", "ethereum"):
        return "ethereum"
    case has("golang", "/go:"):                    return "go"
    case has("node:", "nodejs", "/node"):          return "nodejs"
    case has("python:", "/python"):                return "python"
    case has("ruby:", "/ruby"):                    return "ruby"
    case has("php:", "/php", "laravel"):           return img.contains("laravel") ? "laravel" : "php"
    case has("openjdk", "eclipse-temurin", "amazoncorretto"): return "java"
    case has("rust:", "/rust"):                    return "rust"
    case has("elixir", "/phoenix"):                return "elixir"
    case has("denoland", "/deno"):                 return "deno"
    case has("oven/bun", "/bun"):                  return "bun"
    case has("dotnet", "/aspnet", "mcr.microsoft.com/dotnet"): return "dotnet"
    default:                                        return nil
    }
}

private func brandByName(_ n: String) -> String? {
    func has(_ keys: String...) -> Bool { keys.contains { n.contains($0) } }
    switch true {
    case has("nestjs", "nest-", "-nest"):          return "nestjs"
    case has("nextjs", "next-", "-next"):          return "nextjs"
    case has("react"):                             return "react"
    case has("nuxt", "vuejs", "vue-", "-vue"):     return "vue"
    case has("angular"):                           return "angular"
    case has("svelte"):                            return "svelte"
    case has("django"):                            return "django"
    case has("flask"):                             return "flask"
    case has("laravel"):                           return "laravel"
    case has("rails"):                             return "rails"
    case has("spring"):                            return "spring"
    case has("phoenix", "elixir"):                 return "elixir"
    case has("golang", "-go-", "go-svc", "goapp"): return "go"
    case has("nodejs", "node-", "-node"):          return "nodejs"
    case has("deno"):                              return "deno"
    default:                                        return nil
    }
}
