# Account selection UX (2026-09-15)

This review revisits the existing UX and streamlines it. The baseline is **a flow where the user sees the accounts
already signed in and picks the account for the task about to start**. The harness keeps ownership of authentication and
storage. Different CLI sign-ins are not merged because they share an email or a provider.

## Decisions

- **Connections** in the sidebar opens the **Accounts** section of Settings (2026-10-08; before, a separate connections
  sheet). Existing sign-ins and additional accounts show in the same list. No registration file or credential is copied
  to show an existing sign-in.
- The **Harnesses** section of Settings covers install state and executable settings. Whether an account is signed in
  does not decide whether a harness is installed. The account list can be narrowed with a harness filter and search. At
  first only **Harnesses in use** show (harnesses that have tasks or saved accounts, that an agent ran a subagent on
  with `run_agent` in the last 30 days, or that were chosen for new tasks, or all of them if there are none), and **All
  harnesses** or a single harness is picked in the same filter. For the subagents, Yardlet keeps one preference,
  `Yardlet.subagentHarnessUse`, with each harness's name and the time of its last subagent and nothing else; an entry
  older than 30 days is dropped when a subagent starts or Yardlet launches, and the preference goes once none is left.
  Yardlet's own evaluation judges are not counted.
- As soon as the list opens, each account shows its last looked-up values (account, plan, limits) and "Updated N min.
  ago", and Yardlet looks them up again in the background and updates each one as its answer arrives. A signed-out
  account shows as signed out, and a lookup that could not finish shows "Couldn't refresh · updated N min. ago". Every
  harness uses the same rows, limits and wording.
- There is one account list (`AccountList`), and it shows in four places with the same rows, limits, update wording and
  refresh position (2026-10-08, B5): the popover of the new task's account chip (that harness's default sign-in and
  saved accounts), a task's **Choose account** sheet (only accounts that share that task's history, most remaining limit
  first), the limit card's **Continue with another account** popover (the same list) and Settings › Accounts (harness
  filter and search, grouped by account). An account with only one connection is one row, and when several connections
  are the same account, their connection rows sit under an account header. In the list for moving a task, the current
  account is only shown, accounts that came out signed out at the last check cannot be chosen, and there is no sign-in
  button.
- Account name, harness/provider, remaining limit and reset time are compared in short rows. Long explanations, nested
  cards and repeated select buttons are cut back. Clicking the limit area shows every limit with its exact reset time
  and the last lookup time. When there are more than two items, the list shows +N so nothing is hidden.
- The account is chosen next to the project and harness in the new task composer. The picker shows the default
  connection and additional accounts together, and **Add another account** and **Manage accounts** open directly for
  that harness.
- Adding an account keeps the harness context and leads into sign-in. The account name and folder choice are advanced
  settings. Pi picks the provider first. Sign-in for each provider and API-key entry belong to the CLI.
- Cancelling a new sign-in flow does not change the existing default account. The new task's choice changes when **Use
  this account** is clicked after a successful sign-in. Files the CLI created while trying to sign in are not deleted on
  Yardlet's own judgment.
- No saved connection, provider choice needed, status unavailable and remaining limit not provided are told apart. A CLI
  can run with an environment key or an external provider's authentication even without a saved OAuth sign-in, so
  choosing is not blocked across the board. An account is not chosen when the runtime is missing or a problem with its
  account binding is confirmed.
- Harnesses that do not support a new account environment get no add button that would not work. The account, session ID
  and draft of existing tasks do not change with this selection UI change.

## Flows to check

1. A native account already signed in shows in the list without registration and can be chosen as it is.
2. Several accounts of the same harness and their short-term and long-term limits can be compared and chosen at the same
   time.
3. Add another account does not ask for the harness again, and cancelling returns to the draft being typed.
4. Opening Manage goes straight to the account list narrowed to that harness.
5. Sign-in required and limits not provided are told apart, and an account of another harness is not chosen by mistake.
6. Choosing the default connection keeps the nil binding and does not register the native store again as a new
   environment.
