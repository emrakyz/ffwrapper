- List and extract streams by seeing their codec, channels, bitrates, languages and selecting them conveniently.
- Combine streams by interactively selecting input files and adding optional chapter metadata / movie title in a completely automated way. Any number of audio/subrip files can be used.
- Map streams properly & automatically and detect language codes from filenames and map them to full language names using ISO codes (`iso-codes` package): `deu` and `German`. The audio or subtitle streams and their corresponding metadata will be added with no input (the presence is enough).
- Map colors automatically just by selecting a video source. This includes everything inside `--color-help` menu, even `mastering-display`.
- Format the chapter metadata files found in this URL according to how FFMPEG expects them and automatically add them to final output: `https://chapterdb.plex.tv/browse`. Presence is enough.
- Fixes various common errors (negative timestamps, corrupted packets, sync issues, missing PTS, unreliable or faulty DTS).
- Cut from the whole file or cut by extracting a stream selecting from keyframes (fzf) to ensure proper cutting.
- Encode with Av1an, standalone svt-av1-psy, Opus by automatically creating flags & colors and interactively entering CRF, preset, FG and using sensible defaults.
- Do extensive metric tests (SSIMU2, Weighted XSPNR, VMAF, SSIM/PSNR).
- Extract DOVI RPUs and HDR10+ JSON. Use them automatically.
- Some other conveniences...

https://github.com/user-attachments/assets/431ac63d-3b00-4997-ac4c-f6ac4bac6184

