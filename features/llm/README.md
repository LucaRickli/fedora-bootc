# Local LLM

[shimmy](https://github.com/Michael-A-Kuykendall/shimmy) runs GGUF models on
the GPU through Vulkan, behind an OpenAI-compatible API at
`http://127.0.0.1:11435/v1`. To turn it on for your account, run:

```sh
mkdir -p ~/.local/share/shimmy/models    # put .gguf files here
systemctl --user enable --now shimmy
curl http://127.0.0.1:11435/v1/models
```

It also finds models in `~/models` and the Hugging Face, Ollama, and LM Studio
caches.

> [!WARNING]
> On some GPUs, a request can hang the GPU until the kernel resets it.
