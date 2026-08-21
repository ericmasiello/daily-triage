---
name: daily-triage
description: Decide what to work on right now. Runs the triage-cache binary and opens the HTML report. Use when the user says 'what should I work on', 'triage', 'prioritize', 'what's next', 'pick something up', or wants help deciding which task to tackle.
---

# Triage

Run the binary. It handles everything.

```bash
~/Sites/daily-triage/triage-cache --format html --open html
```

If the binary doesn't exist, build first:

```bash
swiftc -parse-as-library ~/Sites/daily-triage/Sources/*.swift \
  -o ~/Sites/daily-triage/triage-cache
```

If the binary exits with code 1, report the error and stop.
