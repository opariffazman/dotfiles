return {
  {
    "folke/tokyonight.nvim",
    opts = {
      -- Alacritty only applies window.opacity to the default background, so
      -- Neovim must leave the background unset (NONE) for it to show through.
      transparent = true,
      styles = {
        sidebars = "transparent",
        floats = "transparent",
      },
    },
  },
}
