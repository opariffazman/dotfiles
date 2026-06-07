return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      ensure_installed = { "markdown", "markdown_inline", "html", "latex", "yaml" },
    },
  },
  {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-mini/mini.nvim" },
    ft = "markdown",
    opts = {
      heading = { position = "inline" },
      pipe_table = { preset = "round" },
    },
  },
}
