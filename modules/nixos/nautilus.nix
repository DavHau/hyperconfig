# Nautilus right-click "Open in Alacritty" (folder background and folder
# items), via the nautilus-open-any-terminal extension.
{
  programs.nautilus-open-any-terminal = {
    enable = true;
    terminal = "alacritty";
  };
}
