# Python libraries in every agent's writable venv, as a `python.withPackages`
# argument. ./python-venv.nix builds the venv on som; ../hermes-agents-gpu-host.nix
# builds the same set against CUDA on the GPU host.
ps: with ps; [
  numpy
  scipy
  sympy
  pandas
  polars
  pyarrow
  duckdb
  matplotlib
  seaborn
  scikit-learn
  statsmodels
  networkx
  numba
  pillow
  tqdm
  torch
  transformers
  pypdf
  openpyxl
  python-docx
  # nixpkgs `arxiv` currently fails its runtime-deps check. The agent can
  # `pip install arxiv` into the venv when needed.
  wikipedia
  requests
  httpx
  aiohttp
  beautifulsoup4
  lxml
  html5lib
  feedparser
  trafilatura
  scrapy
  pyyaml
  rich
  ipython
]
