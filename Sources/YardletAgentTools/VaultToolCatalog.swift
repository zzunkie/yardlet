import Foundation

/// The vault tool (docs/BROWSER_VAULT_DESIGN.md §5.1): fills a sign-in the person saved in Yardlet into
/// the page. The model names the item; the values go from Yardlet into the page and never back.
/// A task has it while the vault is on and holds an item, next to the browser tools.
package enum VaultToolCatalog {
    package static let fillCredential = "browser_fill_credential"

    package static func definition(named name: String) -> AgentToolDefinition? {
        name == fillCredential ? tool : nil
    }

    package static let tool = AgentToolDefinition(
        name: fillCredential,
        title: "Fill saved sign-in",
        description: "Fill a sign-in saved in the person's Yardlet password manager into a form on the page: the username and "
            + "password, or the current one-time code, or the passkey for the page's next passkey request. For a new "
            + "account, Yardlet makes a strong password, fills it into the new password field and its confirmation, and "
            + "saves it as a new item. Yardlet puts the values into the page itself and does not return them. It fills "
            + "only on the sites the item is saved for.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ref": .object([
                    "type": .string("string"),
                    "description": .string("A field of the sign-in form, from the latest browser_snapshot, such as @e3. "
                        + "Not needed for a passkey.")
                ]),
                "item": .object([
                    "type": .string("string"),
                    "description": .string("The saved item's name or username. Omit when one item is saved for this site. "
                        + "For new_password, the new item's name (the site by default).")
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("login"), .string("one_time_code"), .string("passkey"), .string("new_password")]),
                    "description": .string("login (the default): username and password. one_time_code: the "
                        + "authenticator code. passkey: the item's passkey answers the page's next passkey request "
                        + "within 60 seconds. new_password: a new password for a sign-up form, with ref its new password "
                        + "field, saved with the username the form holds.")
                ]),
                "submit": .object([
                    "type": .string("boolean"),
                    "description": .string("Whether to submit the form after filling it. By default Yardlet submits a form "
                        + "that sends its fields to the page's own address over https (by POST when it holds a password), so "
                        + "the values stay on the page briefly; false leaves it unsent (the first step of a sign-in in steps). "
                        + "A form that would send a password by GET or a secret to another address is never submitted: the "
                        + "result says why. true also presses Enter in a field that is in no form.")
                ]),
                "tabId": .object([
                    "type": .string("string"),
                    "description": .string("The tab to act on, from browser_tab_list or browser_tab_new. Omit for the active tab.")
                ])
            ]),
            "additionalProperties": .bool(false)
        ]),
        readOnly: false
    )
}
