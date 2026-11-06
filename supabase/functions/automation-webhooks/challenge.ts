// The receiver proves possession of the private signing secret. An arbitrary
// public echo service must not be enough to enroll a task-data destination.
const encoder = new TextEncoder();
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
function signed(subscription: string, attempt: string, nonce: string) {
  if (
    !uuid.test(subscription) || !uuid.test(attempt) ||
    !/^[a-f0-9]{64}$/.test(nonce)
  ) throw Error("Invalid webhook challenge");
  return encoder.encode(`verify.v1.${subscription}.${attempt}.${nonce}`);
}
export async function webhookChallengeProof(
  secret: Uint8Array,
  subscription: string,
  attempt: string,
  nonce: string,
) {
  if (secret.length !== 32) throw Error("Invalid receiver secret");
  const key = await crypto.subtle.importKey(
    "raw",
    secret as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, signed(subscription, attempt, nonce)),
  );
  return Array.from(signature, (b) => b.toString(16).padStart(2, "0")).join("");
}
export async function verifyWebhookChallenge(
  response: string | undefined,
  secret: Uint8Array,
  subscription: string,
  attempt: string,
  nonce: string,
) {
  if (
    typeof response !== "string" || response.length > 8192 ||
    secret.length !== 32
  ) return false;
  try {
    const value = JSON.parse(response);
    if (
      !value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== "challenge,proof" ||
      value.challenge !== nonce || typeof value.proof !== "string" ||
      !/^[a-f0-9]{64}$/.test(value.proof)
    ) return false;
    const signature = Uint8Array.from(
      value.proof.match(/../g) as string[],
      (byte) => parseInt(byte, 16),
    );
    const key = await crypto.subtle.importKey(
      "raw",
      secret as BufferSource,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      "HMAC",
      key,
      signature,
      signed(subscription, attempt, nonce),
    );
  } catch {
    return false;
  }
}
