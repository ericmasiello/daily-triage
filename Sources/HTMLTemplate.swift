import Foundation

// MARK: - Page template

func htmlPage(title: String, body: String) -> String {
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(htmlEscape(title))</title>
      <style>\(htmlPageCSS)</style>
    </head>
    <body>
      <div class="container">
        \(body)
      </div>
    </body>
    </html>
    """
}

// MARK: - Stylesheet

private let htmlPageCSS = """

        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        :root {
          --bg: #0d1117;
          --surface: #161b22;
          --surface2: #21262d;
          --border: #30363d;
          --text: #e6edf3;
          --text-muted: #8b949e;
          --accent-blue: #58a6ff;
          --accent-green: #3fb950;
          --accent-yellow: #d29922;
          --accent-red: #f85149;
          --accent-purple: #bc8cff;
          --accent-orange: #e3b341;
          --radius: 8px;
          --radius-sm: 4px;
        }

        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
          background: var(--bg);
          color: var(--text);
          line-height: 1.6;
          padding: 24px 16px 64px;
        }

        .container {
          max-width: 960px;
          margin: 0 auto;
          display: flex;
          flex-direction: column;
          gap: 20px;
        }

        .header-card {
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          padding: 24px;
        }

        .header-top {
          display: flex;
          align-items: flex-start;
          justify-content: space-between;
          gap: 16px;
          flex-wrap: wrap;
        }

        h1 {
          font-size: 1.5rem;
          font-weight: 700;
          color: var(--text);
          line-height: 1.2;
        }

        .timestamp {
          font-size: 0.8rem;
          color: var(--text-muted);
          display: block;
          margin-top: 4px;
        }

        .mode-badge {
          display: inline-flex;
          align-items: center;
          padding: 4px 12px;
          border-radius: 20px;
          font-size: 0.78rem;
          font-weight: 600;
          letter-spacing: 0.03em;
          white-space: nowrap;
          flex-shrink: 0;
        }
        .badge-full {
          background: rgba(88,166,255,0.15); color: var(--accent-blue);
          border: 1px solid rgba(88,166,255,0.3); }
        .badge-nochange {
          background: rgba(63,185,80,0.15); color: var(--accent-green);
          border: 1px solid rgba(63,185,80,0.3); }
        .badge-delta {
          background: rgba(210,153,34,0.15); color: var(--accent-yellow);
          border: 1px solid rgba(210,153,34,0.3); }
        .badge-unknown { background: var(--surface2); color: var(--text-muted); border: 1px solid var(--border); }

        .meta-row {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
          margin-top: 16px;
        }

        .meta-chip {
          display: inline-flex;
          align-items: center;
          gap: 0;
          background: var(--surface2);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          overflow: hidden;
          font-size: 0.78rem;
        }

        .meta-label {
          padding: 3px 8px;
          background: var(--border);
          color: var(--text-muted);
          font-weight: 500;
        }

        .meta-value {
          padding: 3px 8px;
          color: var(--text);
        }

        .recommendation-card {
          background: linear-gradient(135deg, rgba(63,185,80,0.08), rgba(63,185,80,0.04));
          border: 1px solid rgba(63,185,80,0.3);
          border-left: 4px solid var(--accent-green);
          border-radius: var(--radius);
          padding: 20px 24px;
        }

        .rec-label {
          font-size: 0.72rem;
          font-weight: 700;
          letter-spacing: 0.08em;
          text-transform: uppercase;
          color: var(--accent-green);
          margin-bottom: 8px;
        }

        .rec-text {
          font-size: 1.05rem;
          font-weight: 500;
          color: var(--text);
        }

        .section {
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          padding: 24px;
        }

        .section h2 {
          font-size: 1rem;
          font-weight: 700;
          color: var(--text);
          margin-bottom: 16px;
          padding-bottom: 12px;
          border-bottom: 1px solid var(--border);
        }

        .analysis-card {
          background: var(--surface2);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          padding: 20px;
          margin-bottom: 16px;
        }

        .analysis-card:last-child { margin-bottom: 0; }

        .analysis-card h3 {
          font-size: 0.875rem;
          font-weight: 600;
          color: var(--text-muted);
          text-transform: uppercase;
          letter-spacing: 0.05em;
          margin-bottom: 14px;
        }

        .analysis-card--tier1 { border-left: 3px solid var(--accent-blue); }
        .analysis-card--tier2 { border-left: 3px solid var(--accent-purple); }
        .analysis-card--warning { border-left: 3px solid var(--accent-yellow); }

        .mr-table {
          width: 100%;
          border-collapse: collapse;
          font-size: 0.875rem;
        }

        .mr-table th {
          text-align: left;
          padding: 8px 12px;
          font-size: 0.72rem;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: var(--text-muted);
          border-bottom: 1px solid var(--border);
        }

        .mr-table td {
          padding: 10px 12px;
          border-bottom: 1px solid rgba(48,54,61,0.6);
          vertical-align: top;
        }

        .mr-table tr:last-child td { border-bottom: none; }
        .mr-table tr:hover td { background: rgba(88,166,255,0.04); }

        .mr-iid { white-space: nowrap; }
        .mr-iid a { color: var(--accent-blue); text-decoration: none; font-weight: 600; }
        .mr-iid a:hover { text-decoration: underline; }

        .mr-title { max-width: 400px; }
        .mr-age { white-space: nowrap; color: var(--text-muted); text-align: right; }
        .label-row { margin-top: 4px; display: flex; flex-wrap: wrap; gap: 4px; }

        .status-badge {
          display: inline-block;
          padding: 2px 8px;
          border-radius: 20px;
          font-size: 0.72rem;
          font-weight: 600;
          white-space: nowrap;
        }
        .status-approved { background: rgba(63,185,80,0.15); color: var(--accent-green); }
        .status-changes { background: rgba(248,81,73,0.15); color: var(--accent-red); }
        .status-awaiting { background: rgba(88,166,255,0.15); color: var(--accent-blue); }
        .status-other { background: var(--surface); color: var(--text-muted); }

        .label-badge {
          display: inline-block;
          padding: 1px 6px;
          background: rgba(188,140,255,0.12);
          color: var(--accent-purple);
          border-radius: 3px;
          font-size: 0.68rem;
          font-weight: 500;
        }

        .tier-badge {
          display: inline-block;
          padding: 2px 8px;
          background: rgba(227,179,65,0.15);
          color: var(--accent-orange);
          border-radius: 20px;
          font-size: 0.72rem;
          font-weight: 700;
        }

        .tag-list { list-style: none; display: flex; flex-wrap: wrap; gap: 6px; }
        .tag {
          padding: 3px 10px;
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          font-size: 0.78rem;
          font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
          color: var(--text-muted);
        }

        .worktree-list { list-style: none; display: flex; flex-direction: column; gap: 6px; }
        .worktree-list li { font-size: 0.875rem; }

        .changes-list { list-style: none; display: flex; flex-direction: column; gap: 6px; }
        .changes-list li {
          font-size: 0.875rem;
          padding: 8px 12px;
          background: var(--surface2);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
        }

        .previous-report {
          font-size: 0.875rem;
          color: var(--text);
          line-height: 1.7;
        }

        .previous-report h2,
        .previous-report h3,
        .previous-report h4 {
          color: var(--text);
          margin-top: 20px;
          margin-bottom: 8px;
        }

        .previous-report p { margin-bottom: 12px; }
        .previous-report ul { padding-left: 20px; margin-bottom: 12px; }
        .previous-report li { margin-bottom: 4px; }

        .previous-report code {
          font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
          background: var(--surface2);
          border: 1px solid var(--border);
          padding: 1px 5px;
          border-radius: 3px;
          font-size: 0.85em;
        }

        .previous-report pre.code-block {
          background: #010409;
          border: 1px solid var(--border);
          padding: 16px;
          border-radius: var(--radius);
          overflow-x: auto;
          margin: 12px 0;
        }

        .previous-report pre.code-block code {
          background: none;
          border: none;
          padding: 0;
          font-size: 0.82rem;
          color: #c9d1d9;
        }

        .muted { color: var(--text-muted); }

        a { color: var(--accent-blue); }
        a:hover { text-decoration: underline; }

        code {
          font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
          background: var(--surface2);
          border: 1px solid var(--border);
          padding: 1px 5px;
          border-radius: 3px;
          font-size: 0.85em;
        }

        @media (max-width: 600px) {
          .mr-table { font-size: 0.78rem; }
          .mr-title { max-width: 200px; }
          h1 { font-size: 1.25rem; }
        }
"""
