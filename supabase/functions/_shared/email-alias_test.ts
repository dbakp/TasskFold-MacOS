import { emailAliasDomain, emailAliasHash } from "./email-alias.ts";
const assert = (value: unknown) => {
  if (!value) throw Error("Alias contract mismatch");
};
Deno.test("canonical alias SHA256 matches independently calculated native vector", async () => {
  const address = "00".repeat(32) + "@mail.example.invalid";
  // Node crypto independently calculated fixture, also asserted by Swift tests.
  assert(
    await emailAliasHash(address) ===
      "0736b143acb81a8e6e472803f1d5e30bbff26de6a6de5cf3ac7cff5f929a57b7",
  );
  assert(
    await emailAliasHash("01".repeat(32) + "@mail.example.invalid") !==
      await emailAliasHash(address),
  );
});
Deno.test("recipient syntax refuses noncanonical and oversized mailboxes", async () => {
  for (
    const address of [
      "00".repeat(31) + "@mail.example.invalid",
      "AA".repeat(32) + "@mail.example.invalid",
      "00".repeat(32) + "@MAIL.example.invalid",
      "00".repeat(32) + "@mail.example.invalid\nBcc:a@b.test",
      "Name <" + "00".repeat(32) + "@mail.example.invalid>",
      "00".repeat(32) + "@" + "a".repeat(63) + "." + "b".repeat(63) + "." +
      "c".repeat(62),
    ]
  ) {
    let refused = false;
    try {
      await emailAliasHash(address);
    } catch {
      refused = true;
    }
    assert(refused);
  }
});
Deno.test("maximum alias domain retains RFC mailbox length", () => {
  const domain = "a".repeat(63) + "." + "b".repeat(63) + "." + "c".repeat(61);
  assert(
    domain.length === 189 && emailAliasDomain(domain) === domain &&
      emailAliasDomain(domain + "c") === null,
  );
});
