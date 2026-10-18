# TargetForward

Cast on a teammate's enemy without switching away from your teammate.

TargetForward is an Ashita v4 addon developed for Phoenix XI. Select a friendly player who is fighting an enemy, then use a TargetForward spell macro (Example: /tfor Dia). Your spell goes to their combat target while your selection stays on the friendly player.

## Installation

1. Extract the `targetforward` folder into your Ashita `addons` folder.
2. Check that the main file is at `addons/targetforward/targetforward.lua`. Keep the other included Lua files in the same folder.
3. In game, enter:

   ```text
   /addon load targetforward
   ```

4. Enable in the PHX launcher for auto load

Supports LuAshitacast. If you use it, keep your existing spell gear sets.

## Using spell macros

Replace `/ma` with `/tfor` in the macros you want to use with TargetForward:

```text
/tfor "Dia"
/tfor "Stone II"
/tfor "Slow"
/tfor "Katon: Ichi"
```

- **Friendly player selected:** enemy-only spells go to that player's combat target.
- **Enemy selected:** spells use normal casting behavior.
- **No target selected:** spells use normal casting behavior.
- **Healing, buffs and self-only spells:** use normal casting behavior.

You can also specify normal targeting options:

```text
/tfor "Stone II" <t>
/tfor "Cure III" <stpt>
/tfor "Protect" <me>
/tfor "Utsusemi: Ichi" <me>
```

Explicit targets other than `<t>` use normal casting behavior. Ordinary `/ma` macros and spells selected from the magic menu are never changed.

For macros with pauses, put `/wait` on a separate line. Inline waits disable forwarding:

```text
/tfor "Dia"
/wait 3
/tfor "Stone"
```

## Commands

| Command | What it does |
| --- | --- |
| `/tfor "Spell Name"` | Cast a spell using the behavior above. |
| `/tfor reload` | Reload the addon after an update. |
| `/tfor help` | Show command help. |

`/targetforward` works in place of `/tfor` for every command.

## Things to know

- The friendly player must be engaged with an enemy. Simply highlighting an enemy on their screen is not enough.
- You still need the correct job, level, learned spell, MP, Ninja tools or set Blue Magic, as applicable.
- The addon reports why a forwarded cast is blocked. Successful casts have no extra debug messages.
- Range, large-monster allowances and line of sight are handled by the server. A request can still fail under the game's normal rules.
- Rapid duplicate requests are limited to one every half second. The game's normal casting delays and recasts still apply.
