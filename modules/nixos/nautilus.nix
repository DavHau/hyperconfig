# Nautilus right-click "Open in Ghostty" (folder background and folder
# items), via the nautilus-open-any-terminal extension.
{
  programs.nautilus-open-any-terminal = {
    enable = true;
    terminal = "ghostty";
  };
}
