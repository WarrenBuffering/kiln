local M = {}

function M.setup()
  vim.o.background = "dark"
  vim.cmd("highlight clear")
  vim.g.colors_name = "kiln"
  local c = {
    bg = "#111518", panel = "#171D21", raised = "#20292E", fg = "#D9E1E4",
    dim = "#6C7E88", muted = "#97A8AE", amber = "#EDB96B", cyan = "#75C6C3",
    green = "#9FC69C", red = "#EC8C86", blue = "#8BAFCE", violet = "#C3A2CF",
  }
  local groups = {
    Normal = { fg = c.fg, bg = c.bg }, NormalNC = { fg = c.fg, bg = c.bg },
    NormalFloat = { fg = c.fg, bg = c.panel }, FloatBorder = { fg = c.amber, bg = c.panel },
    FloatTitle = { fg = c.amber, bg = c.panel, bold = true },
    CursorLine = { bg = "#1B2328" }, CursorLineNr = { fg = c.amber, bold = true },
    LineNr = { fg = "#4B5C65" }, SignColumn = { bg = c.bg }, EndOfBuffer = { fg = c.bg },
    WinSeparator = { fg = "#34434B", bg = c.bg },
    StatusLine = { fg = c.fg, bg = c.raised }, StatusLineNC = { fg = c.dim, bg = c.panel },
    WinBar = { fg = c.amber, bg = c.panel, bold = true }, WinBarNC = { fg = c.muted, bg = c.panel },
    TabLine = { fg = c.muted, bg = c.panel }, TabLineSel = { fg = c.amber, bg = c.raised, bold = true },
    TabLineFill = { bg = c.panel }, Visual = { bg = "#304650" },
    Search = { fg = c.bg, bg = c.amber }, IncSearch = { fg = c.bg, bg = c.cyan },
    Pmenu = { fg = c.fg, bg = c.raised }, PmenuSel = { fg = c.bg, bg = c.amber },
    Directory = { fg = c.cyan }, Title = { fg = c.amber, bold = true },
    Comment = { fg = c.dim, italic = true }, Constant = { fg = c.amber }, String = { fg = c.green },
    Identifier = { fg = c.fg }, Function = { fg = c.cyan }, Statement = { fg = c.violet },
    PreProc = { fg = c.amber }, Type = { fg = c.blue }, Special = { fg = c.cyan },
    Delimiter = { fg = c.muted }, Error = { fg = c.red }, Todo = { fg = c.amber, bold = true },
    DiffAdd = { bg = "#233B2E" }, DiffChange = { bg = "#27333E" },
    DiffDelete = { fg = "#825C59", bg = "#3A2729" }, DiffText = { bg = "#3C505D", bold = true },
    DiagnosticError = { fg = c.red }, DiagnosticWarn = { fg = c.amber },
    DiagnosticInfo = { fg = c.blue }, DiagnosticHint = { fg = c.cyan },
    KilnTitle = { fg = c.amber, bold = true }, KilnMuted = { fg = c.dim },
    KilnAccent = { fg = c.cyan, bold = true }, KilnSuccess = { fg = c.green },
    KilnError = { fg = c.red }, KilnTool = { fg = c.blue }, KilnBorder = { fg = "#34434B" },
    KilnPanel = { fg = c.fg, bg = c.panel }, KilnUser = { fg = c.amber, bold = true },
    KilnAgent = { fg = c.cyan, bold = true }, KilnRunning = { fg = c.amber },
  }
  for name, value in pairs(groups) do vim.api.nvim_set_hl(0, name, value) end
end

return M
