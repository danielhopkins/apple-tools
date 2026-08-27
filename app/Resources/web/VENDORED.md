# Vendored JavaScript

🛑 **THE APP MAKES NO NETWORK CALLS, AND THAT INCLUDES THE WEB VIEW.** A `<script
src="https://cdn…">` would be a request to a third party from a process holding
Full Disk Access, on every open. So d3 ships inside the bundle and the page
loads it from `file://`.

| file | version | licence | sha256 |
|---|---|---|---|
| `d3.min.js` | [d3 7.9.0](https://github.com/d3/d3/releases/tag/v7.9.0) | ISC — `d3-LICENSE.txt` | `f2094bbf6141b359722c4fe454eb6c4b0f0e42cc10cc7af921fc158fceb86539` |

Refresh it with:

```
curl -sL -o d3.min.js https://cdn.jsdelivr.net/npm/d3@7.9.0/dist/d3.min.js
shasum -a 256 d3.min.js        # must match the table above
```

⚠️ **The whole of d3, not the four modules used.** `d3-force`, `d3-zoom`,
`d3-drag` and `d3-selection` pull in eight more packages between them, and
resolving that by hand is a bundler's job. One known file with a recorded
hash is easier to audit than nine hand-picked ones.
