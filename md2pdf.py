#!/usr/bin/env python3
"""Convert Markdown to PDF using weasyprint."""

import sys
import markdown
from weasyprint import HTML, CSS

def convert_md_to_pdf(md_file, pdf_file):
    with open(md_file, 'r') as f:
        md_content = f.read()

    # Convert markdown to HTML
    html_content = markdown.markdown(
        md_content,
        extensions=['tables', 'fenced_code', 'codehilite', 'toc']
    )

    # Wrap in full HTML document with styling
    full_html = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        @page {{
            size: letter;
            margin: 0.75in;
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            line-height: 1.5;
            font-size: 11px;
        }}
        h1 {{ color: #1a1a1a; border-bottom: 2px solid #ddd; padding-bottom: 10px; }}
        h2 {{ color: #2a2a2a; border-bottom: 1px solid #eee; padding-bottom: 5px; margin-top: 30px; }}
        h3 {{ color: #3a3a3a; margin-top: 25px; }}
        code {{
            background-color: #f4f4f4;
            padding: 2px 6px;
            border-radius: 3px;
            font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
            font-size: 12px;
        }}
        pre {{
            background-color: #f4f4f4;
            padding: 15px;
            border-radius: 5px;
            font-size: 10px;
            white-space: pre-wrap;
            word-wrap: break-word;
            word-break: break-all;
        }}
        pre code {{
            background-color: transparent;
            padding: 0;
        }}
        table {{
            border-collapse: collapse;
            width: 100%;
            margin: 20px 0;
        }}
        th, td {{
            border: 1px solid #ddd;
            padding: 8px 12px;
            text-align: left;
        }}
        th {{
            background-color: #f4f4f4;
            font-weight: 600;
        }}
        tr:nth-child(even) {{
            background-color: #fafafa;
        }}
        blockquote {{
            border-left: 4px solid #ddd;
            margin: 0;
            padding-left: 20px;
            color: #666;
        }}
        a {{
            color: #0366d6;
            text-decoration: none;
            word-wrap: break-word;
            word-break: break-all;
        }}
        a:hover {{
            text-decoration: underline;
        }}
        p, li, td {{
            word-wrap: break-word;
            overflow-wrap: break-word;
        }}
    </style>
</head>
<body>
{html_content}
</body>
</html>"""

    # Convert to PDF
    HTML(string=full_html).write_pdf(pdf_file)
    print(f"Created {pdf_file}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.md output.pdf")
        sys.exit(1)
    convert_md_to_pdf(sys.argv[1], sys.argv[2])
