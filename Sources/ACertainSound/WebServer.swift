import Foundation
import Network

/// Snapshot of playback served to the phone as JSON.
struct ViewerStatus: Codable {
    var show: String
    var theme: String
    var state: String          // "playing" | "paused" | "stopped"
    var ducked: Bool
    var title: String?
    var artist: String?
    var next: String?
    var remaining: Double      // seconds until the music stops
    var elapsed: Double
    var segDur: Double
}

/// A tiny read-only HTTP server on the local network so a second device (e.g. a
/// co-host's phone on the same Wi-Fi / hotspot) can watch now-playing, up-next
/// and the countdown. Serves one page at "/" and a JSON snapshot at "/status".
/// Deliberately not @MainActor: connections are handled on a background queue,
/// with the status snapshot guarded by a lock.
final class WebServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.andrewlong.crocus.webserver")
    private let lock = NSLock()
    private var statusJSON = Data("{}".utf8)
    private let html: Data

    init() { html = Data(WebServer.page.utf8) }

    /// Thread-safe status update (called from the main actor).
    func setStatus(_ data: Data) {
        lock.lock(); statusJSON = data; lock.unlock()
    }

    private func currentStatus() -> Data {
        lock.lock(); defer { lock.unlock() }; return statusJSON
    }

    /// Start on an ephemeral port; `completion` gets the chosen port (or nil).
    func start(completion: @escaping (UInt16?) -> Void) {
        stop()
        do {
            let l = try NWListener(using: .tcp)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:            completion(l.port?.rawValue)
                case .failed, .cancelled: completion(nil)
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            completion(nil)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let path = WebServer.parsePath(data)
            let (type, body): (String, Data) = path.hasPrefix("/status")
                ? ("application/json", self.currentStatus())
                : ("text/html; charset=utf-8", self.html)
            let header = """
            HTTP/1.1 200 OK\r
            Content-Type: \(type)\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            Access-Control-Allow-Origin: *\r
            Connection: close\r
            \r

            """
            var out = Data(header.utf8)
            out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private static func parsePath(_ data: Data?) -> String {
        guard let data, let s = String(data: data, encoding: .utf8) else { return "/" }
        let line = s.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first ?? ""
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }

    /// Best-guess LAN IPv4 address (prefers Wi-Fi / Ethernet).
    static func localIPAddress() -> String? {
        var candidates: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            let ifa = p.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name != "lo0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    candidates[name] = String(cString: host)
                }
            }
            ptr = ifa.ifa_next
        }
        return candidates["en0"] ?? candidates["en1"] ?? candidates.values.first
    }

    // The self-contained page the phone loads. Dark, glanceable, polls /status.
    static let page = """
    <!doctype html><html><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>Crocus</title>
    <style>
      :root { --bg:#0B0E0C; --fg:#EDF2ED; --dim:#8AA090; --accent:#66CC85; }
      * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
      html,body { margin:0; height:100%; background:var(--bg); color:var(--fg);
        font-family:-apple-system,system-ui,sans-serif; -webkit-user-select:none; user-select:none; }
      #app { min-height:100%; display:flex; flex-direction:column; justify-content:space-between;
        padding:max(env(safe-area-inset-top),20px) 22px max(env(safe-area-inset-bottom),20px); }
      .top { display:flex; justify-content:space-between; align-items:center; gap:10px; }
      .show { font-size:15px; font-weight:600; color:var(--dim); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      .pill { font-size:11px; font-weight:700; letter-spacing:1.5px; text-transform:uppercase;
        padding:5px 10px; border-radius:20px; background:#1b241d; color:var(--dim); white-space:nowrap; }
      .pill.live { background:var(--accent); color:var(--bg); }
      .pill.talk { background:var(--accent); color:var(--bg); }
      .mid { display:flex; flex-direction:column; justify-content:center; flex:1; padding:24px 0; }
      .label { font-size:12px; letter-spacing:2px; text-transform:uppercase; color:var(--dim); margin-bottom:10px; }
      .title { font-size:clamp(30px,9vw,64px); font-weight:700; line-height:1.05; }
      .artist { font-size:clamp(17px,5vw,30px); color:var(--dim); margin-top:8px; }
      .count { text-align:right; }
      .count .label { color:var(--dim); }
      .big { font-variant-numeric:tabular-nums; font-weight:200; font-size:clamp(64px,26vw,180px); line-height:1;
        letter-spacing:-2px; }
      .big.warn { color:var(--accent); }
      .next { font-size:15px; color:var(--dim); margin-top:14px; min-height:20px; overflow:hidden;
        text-overflow:ellipsis; white-space:nowrap; }
      .off .title { color:var(--dim); }
    </style></head><body>
    <div id="app">
      <div class="top"><div class="show" id="show">Crocus</div><div class="pill" id="pill">—</div></div>
      <div class="mid">
        <div class="label" id="nplabel">Now playing</div>
        <div class="title" id="title">—</div>
        <div class="artist" id="artist"></div>
      </div>
      <div>
        <div class="count"><div class="label" id="clabel">Music stops in</div><div class="big" id="count">0:00</div></div>
        <div class="next" id="next"></div>
      </div>
    </div>
    <script>
      let remaining = 0, lastSync = Date.now(), state = "stopped";
      const $ = id => document.getElementById(id);
      function mmss(t){ t=Math.max(0,Math.round(t)); return Math.floor(t/60)+":"+String(t%60).padStart(2,"0"); }
      function render(s){
        state = s.state; remaining = s.remaining||0; lastSync = Date.now();
        $("show").textContent = s.theme ? (s.show+" · "+s.theme) : s.show;
        const app = document.getElementById("app");
        app.className = state==="stopped" ? "off" : "";
        const pill = $("pill");
        if (s.ducked){ pill.textContent="Talk"; pill.className="pill talk"; }
        else if (state==="playing"){ pill.textContent="On air"; pill.className="pill live"; }
        else if (state==="paused"){ pill.textContent="Cued"; pill.className="pill"; }
        else { pill.textContent="Off air"; pill.className="pill"; }
        $("nplabel").textContent = state==="paused" ? "Cued next" : "Now playing";
        $("title").textContent = s.title || (state==="stopped" ? "Off air" : "—");
        $("artist").textContent = s.artist || "";
        $("clabel").textContent = s.ducked ? "Bed ends in" : "Music stops in";
        $("next").textContent = s.next ? ("Up next: "+s.next) : "";
        paint();
      }
      function paint(){
        let r = remaining;
        if (state==="playing") r = Math.max(0, remaining - (Date.now()-lastSync)/1000);
        const c = $("count"); c.textContent = mmss(r);
        c.className = "big" + (state!=="stopped" && r<=10 ? " warn" : "");
      }
      async function poll(){
        try { const res = await fetch("/status",{cache:"no-store"}); render(await res.json()); }
        catch(e){}
      }
      setInterval(poll, 1000);
      setInterval(paint, 250);
      poll();
    </script></body></html>
    """
}
