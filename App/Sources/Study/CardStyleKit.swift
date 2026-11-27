import Foundation

enum CardStyleKit {
    static let kitVersion = 1

    struct Theme: Equatable, Hashable, Sendable {
        let scheme: String
        let palette: String
        let oled: Bool
        let white: Bool
        var accent = "#526b63"

        var signature: String { "\(scheme)|\(palette)|\(oled)|\(white)" }

        var variables: String {
            let dark = scheme == "dark"
            let paper = dark ? (oled ? "#000" : "#201e1b") : (white ? "#fff" : "#f6f2e9")
            let raised = dark ? "#2a2723" : "#fffdf7"
            let ink = dark ? "#f0e9db" : "#27231e"
            let soft = dark ? "#c1b8a9" : "#655d52"
            let rule = dark ? "#51493e" : "#d8cfc0"
            return ":root{color-scheme:\(dark ? "dark" : "light");--paper:\(paper);--raised:\(raised);--ink:\(ink);--soft:\(soft);--rule:\(rule);--accent:\(accent)}"
        }
    }

    private static let tokens = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?(?:--!?>|$)|<![^>]*>|<\?[^>]*>|</?([a-z][^\t\n\f\r />]*)(?:\"[^\"]*\"|'[^']*'|[^'\">])*>"#,
        options: .caseInsensitive
    )
    private static let attributes = try! NSRegularExpression(
        pattern: #"[^\t\n\f\r />=]+(?:[\t\n\f\r ]*=[\t\n\f\r ]*(?:\"([^\"]*)\"|'([^']*)'|([^\t\n\f\r >]+)))?"#
    )
    private static let rawText: Set<String> = [
        "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript"
    ]

    static func isOptedIn(_ html: String) -> Bool {
        let source = html as NSString
        let length = source.length
        var cursor = 0
        var inert: [String] = []
        while cursor < length, let token = tokens.firstMatch(in: html, range: NSRange(location: cursor, length: length - cursor)) {
            cursor = NSMaxRange(token.range)
            let nameRange = token.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let name = source.substring(with: nameRange).lowercased()
            let closing = source.character(at: token.range.location + 1) == 47
            if ["template", "svg", "math"].contains(name) {
                if closing {
                    if inert.last == name { inert.removeLast() }
                } else if name == "template" || source.character(at: cursor - 2) != 47 {
                    inert.append(name)
                }
            }
            if !closing && name == "plaintext" { return false }
            if !closing && rawText.contains(name) {
                let end = try! NSRegularExpression(pattern: "</\(name)(?=[\\t\\n\\f\\r />])[^>]*>", options: .caseInsensitive)
                guard let match = end.firstMatch(in: html, range: NSRange(location: cursor, length: length - cursor)) else { return false }
                cursor = NSMaxRange(match.range)
                continue
            }
            guard !closing, name == "meta", inert.isEmpty else { continue }
            let start = NSMaxRange(nameRange)
            var fields: [String: String] = [:]
            for field in attributes.matches(in: html, range: NSRange(location: start, length: cursor - start - 1)) {
                let key = source.substring(with: field.range).prefix { !" \t\r\n\u{000C}=".contains($0) }.lowercased()
                guard fields[key] == nil else { continue }
                let value = (1...3).map { field.range(at: $0) }.first { $0.location != NSNotFound }
                fields[key] = value.map { source.substring(with: $0) } ?? ""
            }
            if fields["name"]?.lowercased() == "clio-card", fields["content"] == "1" { return true }
        }
        return false
    }

    static func injection(theme: Theme) -> String {
        "<style>\(theme.variables)\(css)</style><script>\(javascript)</script>"
    }

    static var totalAssetByteCount: Int { css.utf8.count + javascript.utf8.count }

    private static let css = """
    *,*::before,*::after{box-sizing:border-box}
    body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.55 system-ui;overflow-wrap:anywhere}
    .folio,.digest{max-width:56rem;margin:auto;padding:clamp(16px,5vw,40px)}
    .folio>header,.digest>header{border-bottom:1px solid var(--rule);margin-bottom:1rem;padding-bottom:1rem}
    .folio h1,.digest h1{font:600 clamp(1.8rem,6vw,3rem)/1.15 ui-serif,serif;margin:.4em 0}
    .digest>section{border-top:1px solid var(--rule);padding-block:1rem}
    .clio-grid,.clio-gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,12rem),1fr));gap:12px}
    .clio-kpi,.clio-chart,.clio-calculator,.clio-mat{background:var(--raised);border:1px solid var(--rule);border-radius:14px;padding:12px;margin:0}
    .clio-kpi strong,output{display:block;font-size:1.5rem;font-variant-numeric:tabular-nums}
    .clio-compare{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:8px 12px}
    .clio-compare dd{margin:0;text-align:end;font-variant-numeric:tabular-nums}
    .clio-mat img,.clio-chart svg{display:block;width:100%;height:auto}
    .clio-mat img{border:1px solid var(--rule)}
    figcaption,.clio-muted{color:var(--soft)}
    button,input,summary{font:inherit;min-height:44px;accent-color:var(--accent)}
    input[type=range]{display:block;width:100%;margin:0}
    summary{padding:10px 0;cursor:pointer}
    :focus-visible{outline:2px solid var(--accent);outline-offset:3px}
    .clio-chart output{font-size:1rem;min-height:1.6em}
    .clio-chart svg [tabindex]{cursor:pointer}
    a{color:var(--accent)}
    """

    private static let javascript = #"""
    (() => {
      const ns = 'http://www.w3.org/2000/svg', color = 'var(--accent)';
      const el = (name, attrs) => {
        const node = document.createElementNS(ns, name);
        for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
        return node;
      };
      function chart(card) {
        const kind = card.dataset.clioChart;
        if (!['line','area','bar','donut'].includes(kind)) return;
        let values, labels;
        try {
          values = JSON.parse(card.dataset.values);
          labels = JSON.parse(card.dataset.labels || '[]');
        } catch { return; }
        if (!Array.isArray(values) || !values.length || values.length > 48 ||
            values.some(v => !Number.isFinite(v) || Math.abs(v) > 1e15)) return;
        if (!Array.isArray(labels)) labels = [];
        const svg = el('svg', {viewBox:'0 0 320 180',role:'group'});
        svg.setAttribute('aria-label', card.getAttribute('aria-label') || kind);
        const output = document.createElement('output');
        output.setAttribute('aria-live','polite');
        const target = (node, i) => {
          const label = String(labels[i] ?? i+1) + ' · ' + values[i].toLocaleString();
          const show = () => { output.textContent = label; };
          node.setAttribute('tabindex','0');
          node.setAttribute('role','button');
          node.setAttribute('aria-label',label);
          node.addEventListener('focus',show);
          node.addEventListener('click',show);
          node.addEventListener('keydown', e => {
            if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); show(); }
          });
          svg.append(node);
        };
        if (kind === 'donut') {
          const total = values.reduce((sum,v) => sum + Math.max(0,v),0);
          let offset = 0;
          values.forEach((v,i) => {
            if (v <= 0 || !total) return;
            const portion = v / total * 100;
            target(el('circle',{cx:160,cy:90,r:60,fill:'none',stroke:color,
              'stroke-opacity':Math.max(.22,1-i*.13),'stroke-width':24,
              pathLength:100,'stroke-dasharray':portion+' '+(100-portion),
              'stroke-dashoffset':-offset,transform:'rotate(-90 160 90)'}),i);
            offset += portion;
          });
        } else {
          const min = Math.min(0,...values), max = Math.max(0,...values);
          const step = 296 / values.length;
          const y = v => 164 - (v-min) / (max-min || 1) * 148;
          const zero = y(0);
          const points = values.map((v,i) => [12+step*(i+.5),y(v)]);
          svg.append(el('path',{d:'M12 '+zero+'H308',stroke:'var(--rule)'}));
          if (kind === 'line' || kind === 'area') {
            const path = points.map(p => p.join(',')).join(' L');
            if (kind === 'area') {
              svg.append(el('path',{d:'M'+points[0][0]+','+zero+' L'+path+
                ' L'+points.at(-1)[0]+','+zero+' Z',fill:color,opacity:.2}));
            }
            svg.append(el('path',{d:'M'+path,fill:'none',stroke:color,'stroke-width':2}));
          }
          points.forEach(([x,h],i) => {
            if (kind === 'bar') svg.append(el('rect',{x:x-step*.32,y:Math.min(h,zero),
              width:step*.64,height:Math.max(1,Math.abs(zero-h)),fill:color,rx:2}));
            else svg.append(el('circle',{cx:x,cy:h,r:3.5,fill:color}));
            target(el('rect',{x:x-step/2,y:0,width:step,height:180,fill:'transparent'}),i);
          });
        }
        card.append(svg,output);
      }
      function calculator(card) {
        const inputs = [...card.querySelectorAll('input[type=number], input[type=range]')];
        const output = card.querySelector('output'), op = card.dataset.clioCalculate;
        if (!output || !['sum','product','difference','ratio'].includes(op)) return;
        const update = () => {
          const values = inputs.map(input => input.valueAsNumber);
          let result;
          if (values.length && values.every(Number.isFinite)) {
            if (op === 'sum') result = values.reduce((a,b) => a+b);
            if (op === 'product') result = values.reduce((a,b) => a*b);
            if (op === 'difference' && values.length === 2) result = values[0]-values[1];
            if (op === 'ratio' && values.length === 2) result = values[0]/values[1];
          }
          output.value = Number.isFinite(result) ? result.toLocaleString() : '—';
        };
        card.addEventListener('input',update);
        update();
      }
      document.addEventListener('DOMContentLoaded', () => {
        document.querySelectorAll('[data-clio-chart]').forEach(chart);
        document.querySelectorAll('[data-clio-calculate]').forEach(calculator);
      }, {once:true});
    })();
    """#
}
