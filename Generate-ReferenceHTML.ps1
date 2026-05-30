<#
.SYNOPSIS
    Generates a complete HTML reference with functions, descriptions, parameters, and examples.

.DESCRIPTION
    Reads all .ps1 files from the Public directory, extracts function metadata including:
    - Function name
    - Synopsis (description)
    - Parameters with types
    - Examples (all .EXAMPLE blocks)

    Output: sqmSQLTool-reference-full.html (standalone HTML with search, sidebar, dark theme)
#>

$sourcePath = Split-Path $PSCommandPath
$publicDir = Join-Path $sourcePath "Public"
$outputFile = Join-Path $sourcePath "Docs\sqmSQLTool-reference-full.html"

if (-not (Test-Path $publicDir)) {
    Write-Error "Public directory not found: $publicDir"
    exit 1
}

$functions = @()

Get-ChildItem $publicDir -Filter "*.ps1" | ForEach-Object {
    $content = Get-Content $_.FullName -Raw

    # Extract function name
    if ($content -match 'function\s+([\w-]+)\s*\{') {
        $funcName = $matches[1]

        # Extract SYNOPSIS
        $synopsis = ""
        if ($content -match '\.SYNOPSIS\s*\r?\n\s*(.+?)(?:\r?\n\s*\.|$)') {
            $synopsis = $matches[1].Trim()
        }

        # Extract all PARAMETERS
        $params = @()
        [regex]::Matches($content, '\[\s*Parameter[^\]]*\]\s*(?:\[[^\]]+\]\s*)*\$(\w+)') | ForEach-Object {
            $params += $_.Groups[1].Value
        }

        # Extract all EXAMPLES
        $examples = @()
        [regex]::Matches($content, '\.EXAMPLE\s*\r?\n((?:[^\r\n]|\r\n(?!\s*\.))*)', [System.Text.RegularExpressions.RegexOptions]::Multiline) | ForEach-Object {
            $exampleText = $_.Groups[1].Value.Trim()
            if ($exampleText) {
                $examples += $exampleText
            }
        }

        $functions += [PSCustomObject]@{
            Name     = $funcName
            Synopsis = $synopsis
            Params   = $params
            Examples = $examples
        }
    }
}

$functions = $functions | Sort-Object Name

# Create functions JSON
$functionsJson = $functions | ConvertTo-Json -Depth 10

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>sqmSQLTool - Command Reference</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background-color: #060f20;
            color: #e2e8f0;
            line-height: 1.6;
        }

        .psdb-st {
            display: flex;
            min-height: 100vh;
        }

        .psdb-st-sidebar {
            width: 280px;
            background-color: #0b1e3d;
            padding: 2rem 0;
            border-right: 1px solid #1e3a5f;
            position: fixed;
            height: 100vh;
            overflow-y: auto;
            top: 0;
            left: 0;
        }

        .psdb-st-sidebar-title {
            padding: 0 1.5rem;
            margin-bottom: 1.5rem;
            font-size: 0.875rem;
            font-weight: 600;
            color: #94a8c0;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }

        .psdb-st-sidebar-search {
            padding: 0 1rem 1rem;
            margin-bottom: 1.5rem;
        }

        .psdb-st-sidebar-search input {
            width: 100%;
            padding: 0.5rem 0.75rem;
            background-color: #051329;
            border: 1px solid #1e3a5f;
            border-radius: 0.375rem;
            color: #e2e8f0;
            font-size: 0.875rem;
        }

        .psdb-st-sidebar-search input:focus {
            outline: none;
            border-color: #2e86c1;
            background-color: #051329;
        }

        .psdb-st-sidebar-list {
            list-style: none;
            padding: 0 0.5rem;
        }

        .psdb-st-sidebar-item {
            margin-bottom: 0.25rem;
        }

        .psdb-st-sidebar-link {
            display: block;
            padding: 0.5rem 1rem;
            color: #94a8c0;
            text-decoration: none;
            border-radius: 0.375rem;
            font-size: 0.875rem;
            transition: all 0.2s ease;
        }

        .psdb-st-sidebar-link:hover {
            background-color: #1e3a5f;
            color: #e2e8f0;
        }

        .psdb-st-sidebar-link.active {
            background-color: #2e86c1;
            color: #ffffff;
            font-weight: 600;
        }

        .psdb-st-content {
            flex: 1;
            margin-left: 280px;
            padding: 2rem 3rem;
            max-width: 1400px;
            margin-right: auto;
        }

        .psdb-st-header {
            margin-bottom: 3rem;
        }

        .psdb-st-h1 {
            font-size: 2.5rem;
            font-weight: 700;
            margin-bottom: 0.5rem;
            background: linear-gradient(160deg, #2e86c1 0%, #5dade2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .psdb-st-subtitle {
            color: #94a8c0;
            font-size: 1rem;
        }

        .psdb-st-functions {
            display: grid;
            grid-template-columns: 1fr;
            gap: 2rem;
        }

        .psdb-st-card {
            background-color: #0b1e3d;
            border: 1px solid #1e3a5f;
            border-radius: 0.5rem;
            padding: 2rem;
            transition: all 0.2s ease;
        }

        .psdb-st-card:hover {
            border-color: #2e86c1;
            box-shadow: 0 0 20px rgba(46, 134, 193, 0.1);
        }

        .psdb-st-card-title {
            font-size: 1.25rem;
            font-weight: 600;
            color: #5dade2;
            margin-bottom: 0.75rem;
            font-family: 'Courier New', monospace;
        }

        .psdb-st-card-synopsis {
            color: #e2e8f0;
            margin-bottom: 1rem;
            line-height: 1.6;
        }

        .psdb-st-section-title {
            font-size: 0.875rem;
            font-weight: 700;
            color: #94a8c0;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-top: 1rem;
            margin-bottom: 0.5rem;
        }

        .psdb-st-params {
            list-style: none;
            margin-bottom: 1rem;
        }

        .psdb-st-param {
            padding: 0.5rem 0;
            color: #94a8c0;
            font-family: 'Courier New', monospace;
            font-size: 0.875rem;
            margin-left: 0;
        }

        .psdb-st-param::before {
            content: '→ ';
            color: #2e86c1;
            margin-right: 0.5rem;
        }

        .psdb-st-examples {
            margin-top: 1rem;
        }

        .psdb-st-example {
            background-color: #051329;
            border-left: 3px solid #2e86c1;
            padding: 1rem;
            margin-bottom: 0.75rem;
            border-radius: 0.25rem;
            font-family: 'Courier New', monospace;
            font-size: 0.875rem;
            color: #94a8c0;
            white-space: pre-wrap;
            word-wrap: break-word;
            line-height: 1.4;
        }

        .psdb-st-no-data {
            color: #94a8c0;
            font-style: italic;
        }

        @media (max-width: 1024px) {
            .psdb-st-sidebar {
                width: 250px;
            }
            .psdb-st-content {
                margin-left: 250px;
                padding: 1.5rem 2rem;
            }
        }

        @media (max-width: 768px) {
            .psdb-st {
                flex-direction: column;
            }
            .psdb-st-sidebar {
                position: relative;
                width: 100%;
                height: auto;
                border-right: none;
                border-bottom: 1px solid #1e3a5f;
            }
            .psdb-st-content {
                margin-left: 0;
                padding: 1rem;
            }
            .psdb-st-h1 {
                font-size: 1.75rem;
            }
        }

        .hidden {
            display: none;
        }
    </style>
</head>
<body>
    <div class="psdb-st">
        <aside class="psdb-st-sidebar">
            <div class="psdb-st-sidebar-title">Functions</div>
            <div class="psdb-st-sidebar-search">
                <input type="text" id="search" placeholder="Search...">
            </div>
            <ul class="psdb-st-sidebar-list" id="function-list"></ul>
        </aside>

        <main class="psdb-st-content">
            <div class="psdb-st-header">
                <h1 class="psdb-st-h1">sqmSQLTool</h1>
                <p class="psdb-st-subtitle">Command Reference - $($functions.Count) Functions</p>
            </div>

            <div class="psdb-st-functions" id="functions-container"></div>
        </main>
    </div>

    <script>
        const functions = $functionsJson;

        function renderFunctions(toRender) {
            const container = document.getElementById('functions-container');
            container.innerHTML = '';

            toRender.forEach(func => {
                const card = document.createElement('div');
                card.className = 'psdb-st-card';
                card.id = 'func-' + func.Name.toLowerCase().replace(/[^a-z0-9-]/g, '');

                let paramsHtml = '';
                if (func.Params && func.Params.length > 0) {
                    paramsHtml = '<div class="psdb-st-section-title">Parameters</div><ul class="psdb-st-params">';
                    func.Params.forEach(p => {
                        paramsHtml += '<li class="psdb-st-param">' + escapeHtml(p) + '</li>';
                    });
                    paramsHtml += '</ul>';
                }

                let examplesHtml = '';
                if (func.Examples && func.Examples.length > 0) {
                    examplesHtml = '<div class="psdb-st-section-title">Examples</div><div class="psdb-st-examples">';
                    func.Examples.forEach(ex => {
                        examplesHtml += '<div class="psdb-st-example">' + escapeHtml(ex) + '</div>';
                    });
                    examplesHtml += '</div>';
                }

                card.innerHTML = `
                    <div class="psdb-st-card-title">\${escapeHtml(func.Name)}</div>
                    <div class="psdb-st-card-synopsis">\${escapeHtml(func.Synopsis || 'No description available')}</div>
                    \${paramsHtml}
                    \${examplesHtml}
                `;

                container.appendChild(card);
            });
        }

        function filterFunctions() {
            const query = document.getElementById('search').value.toLowerCase();
            const filtered = functions.filter(f =>
                f.Name.toLowerCase().includes(query) ||
                (f.Synopsis && f.Synopsis.toLowerCase().includes(query))
            );

            document.querySelectorAll('.psdb-st-card').forEach(card => {
                if (filtered.find(f => 'func-' + f.Name.toLowerCase().replace(/[^a-z0-9-]/g, '') === card.id)) {
                    card.classList.remove('hidden');
                } else {
                    card.classList.add('hidden');
                }
            });

            updateSidebar(filtered);
        }

        function updateSidebar(toShow) {
            const list = document.getElementById('function-list');
            list.innerHTML = '';
            toShow.forEach(func => {
                const item = document.createElement('li');
                item.className = 'psdb-st-sidebar-item';
                const link = document.createElement('a');
                link.className = 'psdb-st-sidebar-link';
                link.href = '#func-' + func.Name.toLowerCase().replace(/[^a-z0-9-]/g, '');
                link.textContent = func.Name;
                item.appendChild(link);
                list.appendChild(item);
            });
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        // Initialize
        renderFunctions(functions);
        updateSidebar(functions);

        document.getElementById('search').addEventListener('input', filterFunctions);
    </script>
</body>
</html>
"@

# Write output
$html | Out-File $outputFile -Encoding UTF8 -Force
$fileSize = (Get-Item $outputFile).Length / 1024
Write-Host "✓ Generated: $outputFile" -ForegroundColor Green
Write-Host "  Functions: $($functions.Count)"
Write-Host "  File size: $([Math]::Round($fileSize, 1)) KB"
Write-Host "  Examples: YES"
