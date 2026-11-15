# Scroll animation comparison

Local preview: http://localhost:4173/?design=scroll

Current design: http://localhost:4173/?design=original

This animated design is now the default, following approval to deploy it. It keeps StageSight's green, sage and white palette. The prior layout remains available with `?design=original` for rollback.

The revised concept uses full-width top navigation, a screen-filling CSS sculpture, oversized typography, a moving text band, scroll-linked hero movement, large sticky practice cards, viewport reveals, and a scroll progress line. Native scrolling remains in control. Reduced-motion preferences disable animation by default; an explicit Play animations / Pause animations control lets the user preview it. The underlying recording, auth, storage and AI modules are unchanged.

To restore the prior design as the default, change the loader near the start of `dist/motion.js` to load only when `design=scroll`. The prior layout is also directly available with `?design=original`.

Checked: JavaScript syntax, desktop and 390px phone layouts without horizontal overflow, comparison URL, motion-enabled reveal classes, reduced-motion rendering, and browser error log. These checks do not verify recording or backend behavior.
