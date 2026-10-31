# jobs

Planned: a job system for work that can run off the main thread, such as asset decoding and
texture uploads. Nothing lives here yet. Texture uploads are asynchronous through SDL_GPU
(renderer/texture.zig) and do not need it.
