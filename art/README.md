# Art

`hero/` holds every picture the wall draws: one still per stage (`full`, `medium`, `low`, `dead`), the `ghost`, and
8-frame strips (`*_walk.png`, `dead_idle.png`). One picture pixel is one scene pixel (5 screen pixels at 960×640).

They were made with [SpriteCook](https://www.spritecook.ai): the base character drawn from Claude Code's terminal
logo, every stage as an edit of that same sprite (so size, shape and colours stay identical), and the strips with
SpriteCook's animation tool. SpriteCook's terms let the person who generated an output use, reproduce and
distribute it.

Clawd is the Claude Code mascot by Anthropic. These pictures are fan art; Anthropic does not endorse this project.

## License for the pictures

Copyright (c) 2026 porgeeratad.

You may use, copy, modify and redistribute the pictures in `art/` (and the copies embedded in `web/index.html`) as
part of Usage Wall or of a modified version of it, such as a fork. Using them outside Usage Wall needs separate
permission.

This covers only what the author can grant. It gives no rights in Anthropic's trademarks or characters, including
Claude, Claude Code and Clawd.

## Changing a picture

1. Replace the PNG in `hero/` (transparent background, same pixel scale).
2. For an animation, `uv run --with pillow python art/anim_strip.py SHEET.png art/hero/NAME.png` turns an 8-frame
   sprite sheet into a cleaned strip.
3. `python3 art/embed.py` writes all of `hero/` into `web/index.html` (the server only serves that one page).
4. Preview: `http://127.0.0.1:8765/?weekly=45&act=walk` (see the README's Development section).
