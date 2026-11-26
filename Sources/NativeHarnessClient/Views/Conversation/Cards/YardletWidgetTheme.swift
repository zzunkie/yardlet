import Foundation

/// The stylesheet a `show_widget` view's fragment gets in place of the Codex skill's kit (docs/CONVERSATION_MEDIA.md,
/// "Views from other harnesses"): Yardlet's light and dark surfaces, text and status colors as `--y-*` variables, and
/// quiet defaults for plain elements, so a view without styles of its own reads like the conversation around it.
///
/// Every default sits in `:where(…)`, which has no specificity, so any rule the widget writes wins. The page stays
/// transparent over the conversation's canvas, and nothing is loaded from outside: the system fonts, no images.
/// Colors are the defaults of docs/DESIGN_SYSTEM.md ("Semantic colors"); text and status colors keep 4.5:1 on the
/// canvas, the surface and the elevated surface in both appearances.
enum YardletWidgetTheme {
    static let stylesheet = """
    :root{color-scheme:light dark;
    --y-bg:#FCFCFC;--y-surface:#F4F5F7;--y-surface-elevated:#FFFFFF;--y-input:#FFFFFF;
    --y-text:#1D1D1F;--y-text-secondary:#5F6066;--y-border:rgba(0,0,0,.095);--y-border-strong:rgba(0,0,0,.16);
    --y-fill:rgba(0,0,0,.035);--y-fill-hover:rgba(0,0,0,.062);--y-fill-selected:rgba(0,0,0,.095);
    --y-accent:#0A62C9;--y-on-accent:#FFFFFF;--y-success:#1B7A3A;--y-warning:#985500;--y-danger:#C4291F;
    --y-radius-control:6px;--y-radius:8px;--y-radius-surface:12px;
    --y-font-sans:-apple-system,BlinkMacSystemFont,"SF Pro Text","Apple SD Gothic Neo",system-ui,sans-serif;
    --y-font-mono:ui-monospace,"SF Mono",Menlo,monospace}
    @media (prefers-color-scheme:dark){:root{
    --y-bg:#191A1B;--y-surface:#202124;--y-surface-elevated:#27282C;--y-input:#2C2D31;
    --y-text:#ECECEE;--y-text-secondary:#A3A4AA;--y-border:rgba(255,255,255,.105);--y-border-strong:rgba(255,255,255,.18);
    --y-fill:rgba(255,255,255,.035);--y-fill-hover:rgba(255,255,255,.062);--y-fill-selected:rgba(255,255,255,.095);
    --y-accent:#6AABFF;--y-on-accent:#111214;--y-success:#5AD37E;--y-warning:#F5B14C;--y-danger:#FF7A70}}
    :where(html){-webkit-text-size-adjust:100%;accent-color:var(--y-accent)}
    :where(body){margin:0;padding:0;background:transparent;color:var(--y-text);font:14px/1.5 var(--y-font-sans);
    -webkit-font-smoothing:antialiased}
    :where(*,*::before,*::after){box-sizing:border-box}
    :where(h1,h2,h3,h4){margin:0 0 8px;font-weight:600;line-height:1.3}
    :where(h1){font-size:18px}:where(h2){font-size:16px}:where(h3){font-size:14px}
    :where(h4){font-size:13px;color:var(--y-text-secondary)}
    :where(p,ul,ol,dl,figure,blockquote){margin:0 0 12px}
    :where(small,figcaption,caption,.y-muted){color:var(--y-text-secondary);font-size:12px}
    :where(a){color:var(--y-accent);text-decoration:underline;text-underline-offset:2px}
    :where(hr){border:0;border-top:1px solid var(--y-border);margin:16px 0}
    :where(svg text){fill:currentColor}
    :where(code,kbd,samp,pre){font-family:var(--y-font-mono);font-size:12px}
    :where(:not(pre)>code,kbd){padding:1px 4px;border-radius:4px;background:var(--y-fill-hover)}
    :where(pre){margin:0 0 12px;padding:12px;overflow:auto;border:1px solid var(--y-border);border-radius:var(--y-radius);
    background:var(--y-surface);line-height:1.5}
    :where(table){width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums;margin:0 0 12px}
    :where(th,td){padding:8px 12px;text-align:left;border-bottom:1px solid var(--y-border);vertical-align:top}
    :where(th){font-size:12px;font-weight:600;color:var(--y-text-secondary)}
    :where(tbody tr:hover){background:var(--y-fill)}
    :where(td.num,th.num,.y-num){text-align:right;font-variant-numeric:tabular-nums}
    :where(button,input,select,textarea){font:inherit;font-size:13px;color:inherit}
    :where(button,input[type=button],input[type=submit],input[type=reset]){min-height:28px;padding:0 12px;
    border:1px solid var(--y-border-strong);border-radius:var(--y-radius-control);background:var(--y-surface-elevated);
    cursor:pointer}
    :where(button,input[type=button],input[type=submit],input[type=reset]):hover{background:var(--y-fill-hover)}
    :where(button.y-primary,button[type=submit],input[type=submit]){background:var(--y-accent);border-color:transparent;
    color:var(--y-on-accent);font-weight:500}
    :where(button.y-primary,button[type=submit],input[type=submit]):hover{filter:brightness(1.08)}
    :where(button:disabled,input:disabled,select:disabled,textarea:disabled){opacity:.5;cursor:default}
    :where(input:not([type=checkbox],[type=radio],[type=range],[type=color],[type=button],[type=submit],[type=reset]),
    select,textarea){min-height:28px;padding:4px 8px;border:1px solid var(--y-border-strong);
    border-radius:var(--y-radius-control);background:var(--y-input)}
    :where(textarea){min-height:64px;line-height:1.5}
    :where(input[type=range]){width:100%;accent-color:var(--y-accent)}
    :where(:focus-visible){outline:2px solid var(--y-accent);outline-offset:1px}
    :where(label){font-size:13px}
    :where(progress,meter){accent-color:var(--y-accent)}
    :where(.y-card){padding:16px;border:1px solid var(--y-border);border-radius:var(--y-radius-surface);
    background:var(--y-surface-elevated)}
    :where(.y-grid){display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(160px,1fr))}
    :where(.y-kpi){font-size:24px;font-weight:600;line-height:1.2;font-variant-numeric:tabular-nums}
    :where(.y-badge){display:inline-flex;align-items:center;gap:4px;padding:2px 8px;border-radius:999px;font-size:12px;
    font-weight:500;background:var(--y-fill-hover);color:var(--y-text-secondary)}
    :where(.y-success){color:var(--y-success)}:where(.y-warning){color:var(--y-warning)}
    :where(.y-danger){color:var(--y-danger)}
    :where(.y-badge.y-success){background:color-mix(in srgb,var(--y-success) 12%,transparent)}
    :where(.y-badge.y-warning){background:color-mix(in srgb,var(--y-warning) 12%,transparent)}
    :where(.y-badge.y-danger){background:color-mix(in srgb,var(--y-danger) 12%,transparent)}
    ::-webkit-scrollbar{width:10px;height:10px}
    ::-webkit-scrollbar-thumb{border:2px solid transparent;border-radius:999px;background:var(--y-border-strong) padding-box}
    ::-webkit-scrollbar-track{background:transparent}
    """
}
