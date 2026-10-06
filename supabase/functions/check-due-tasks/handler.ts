/** Compatibility boundary for existing web notifications. Native occurrence delivery is separate. */
export interface Config { url: string; serviceKey: string; cronSecret: string; appID: string; providerKey: string }
interface Task { id: string; title: string; user_id: string }
interface Profile { user_id: string; onesignal_player_id: string | null; preferences: { notifications?: { enabled?: boolean } } | null }
type Transport = (request: Request) => Promise<Response>;
const json = (status: number, value: unknown) => new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
function equal(a: string, b: string): boolean {
  // Bounded comparison without an early mismatch exit. This secret is for service calls only.
  if (a.length !== b.length || b.length < 1 || b.length > 512) return false;
  let difference = 0;
  for (let i = 0; i < b.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
}
export function createHandler(config: Config, options: { send?: Transport; now?: () => Date } = {}) {
  const send = options.send ?? ((request: Request) => fetch(request));
  const now = options.now ?? (() => new Date());
  return async (req: Request): Promise<Response> => {
    if (!config.cronSecret || !equal(req.headers.get("x-cron-secret") ?? "", config.cronSecret)) return json(401, { error: "Unauthorized" });
    if (req.method !== "POST") return json(405, { error: "Use POST" });
    if (!config.serviceKey || !config.appID || !config.providerKey || !/^https:\/\//.test(config.url)) return json(503, { error: "Delivery configuration unavailable" });
    const db = async (path: string, init: RequestInit = {}) => {
      const response = await send(new Request(config.url + "/rest/v1/" + path, { ...init, headers: {
        apikey: config.serviceKey, Authorization: "Bearer " + config.serviceKey, "Content-Type": "application/json", ...init.headers,
      } }));
      if (!response.ok) { await response.body?.cancel().catch(() => {}); throw new Error("database"); }
      return response;
    };
    try {
      const time = now();
      // Preserve the existing web worker's UTC minute model while the versioned worker is built.
      const day = time.toISOString().slice(0, 10), clock = time.toISOString().slice(11, 16);
      const query = new URLSearchParams({ select: "id,title,user_id", due_date: "eq." + day, due_time: "eq." + clock, completed: "eq.false", notification_sent_at: "is.null" });
      const tasks: Task[] = await (await db("tasks?" + query)).json();
      if (!Array.isArray(tasks)) throw new Error("database");
      if (tasks.length === 0) return json(200, { message: "No tasks due soon", count: 0 });
      const users = [...new Set(tasks.map((t) => t.user_id))];
      const profiles: Profile[] = await (await db("profiles?" + new URLSearchParams({ select: "user_id,onesignal_player_id,preferences", user_id: "in.(" + users.join(",") + ")", onesignal_player_id: "not.is.null" }))).json();
      if (!Array.isArray(profiles)) throw new Error("database");
      const recipients = new Map(profiles.filter((p) => p.onesignal_player_id && p.preferences?.notifications?.enabled !== false).map((p) => [p.user_id, p.onesignal_player_id!]));
      let sent = 0, failed = 0;
      for (const task of tasks) {
        const subscription = recipients.get(task.user_id);
        if (!subscription) continue;
        try {
          const response = await send(new Request("https://onesignal.com/api/v1/notifications", {
            method: "POST", headers: { "Content-Type": "application/json", Authorization: "Basic " + config.providerKey },
            body: JSON.stringify({ app_id: config.appID, include_subscription_ids: [subscription], headings: { en: "Task Due Now" }, contents: { en: `"${task.title}" is due now!` }, url: "https://taskfold.co/today", chrome_web_badge: "https://taskfold.co/icon-192.png", chrome_web_icon: "https://taskfold.co/icon-192.png" }),
          }));
          const accepted = response.ok;
          await response.body?.cancel().catch(() => {});
          if (!accepted) { failed++; continue; }
          const saved = await db("tasks?" + new URLSearchParams({ id: "eq." + task.id }), { method: "PATCH", body: JSON.stringify({ notification_sent_at: now().toISOString() }) });
          await saved.body?.cancel().catch(() => {});
          sent++;
        } catch { failed++; }
      }
      // Never log titles, subscription IDs, provider response bodies, tokens or exception text.
      return json(200, { message: "Notifications processed", sent, failed });
    } catch { return json(502, { error: "Reminder delivery could not be completed" }); }
  };
}
