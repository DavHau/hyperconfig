# Planted on the caller's PYTHONPATH: runs in any interpreter that takes it.
open("/home/alice/evil-loaded", "a").write("sitecustomize\n")
