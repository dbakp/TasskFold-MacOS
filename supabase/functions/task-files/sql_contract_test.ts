import { createTaskFilesHandler } from "./handler.ts";
import stoppedSQL from "../../../TaskfoldTests/Fixtures/task-file-sender-stop-v1.json" with {
  type: "json",
};
import captured from "../../../TaskfoldTests/Fixtures/task-file-upload-v1.json" with {
  type: "json",
};

Deno.test("actual SQL publication receipt survives a lost-reply gateway retry", async () => {
  const receipt = captured.published.receipt;
  const session = crypto.randomUUID();
  const token = "e30." +
    btoa(JSON.stringify({ sub: receipt.account, session_id: session }))
      .replaceAll("=", "") +
    ".signature";
  let calls = 0;
  const handler = createTaskFilesHandler({
    url: "https://taskfold.invalid",
    serviceKey: "synthetic-service-key",
    enabled: true,
  }, {
    send: async (request) => {
      calls++;
      const path = new URL(request.url).pathname;
      if (path === "/auth/v1/user") {
        return Response.json({ id: receipt.account });
      }
      if (path !== "/rest/v1/rpc/taskfold_task_file_command") {
        throw new Error("Retry must not upload again");
      }
      const body = await request.json();
      if (
        body._action !== "reserve_fenced" || body._actor !== receipt.account ||
        body._session !== session ||
        JSON.stringify(body._body) !== JSON.stringify(captured.intent)
      ) throw new Error("Wrong authenticated SQL contract");
      return Response.json(captured.published);
    },
  });
  const result = await handler(
    new Request("https://edge.invalid/task-files?action=publish", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer " + token,
      },
      body: JSON.stringify({
        intent: captured.intent,
        bytes_base64: btoa("hello"),
      }),
    }),
  );
  if (
    result.status !== 200 ||
    JSON.stringify(await result.json()) !== JSON.stringify({ receipt }) ||
    calls !== 2
  ) throw new Error("Actual SQL receipt was not recovered exactly");
});

Deno.test("actual SQL sender stop is accepted without any task or provider read", async () => {
  const proof = stoppedSQL.wire.reply.receipt, session = crypto.randomUUID();
  let calls = 0;
  const token = "e30." +
    btoa(JSON.stringify({ sub: proof.account, session_id: session }))
      .replaceAll("=", "") +
    ".signature";
  const handler = createTaskFilesHandler({
    url: "https://taskfold.invalid",
    serviceKey: "synthetic-service-key",
    enabled: false,
  }, {
    send: async (request) => {
      calls++;
      const path = new URL(request.url).pathname;
      if (path === "/auth/v1/user") return Response.json({ id: proof.account });
      if (path !== "/rest/v1/rpc/taskfold_task_file_command") {
        throw new Error("Sender stop must not read provider bytes");
      }
      const body = await request.json();
      if (
        body._action !== "cancel" || body._actor !== proof.account ||
        body._session !== session ||
        body._body.operation_id !== proof.operation_id
      ) throw new Error("Incorrect sender scope");
      return Response.json({ status: "cancelled", receipt: proof });
    },
  });
  const result = await handler(
    new Request("https://edge.invalid/task-files?action=cancel", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer " + token,
      },
      body: JSON.stringify({ operation_id: proof.operation_id }),
    }),
  );
  if (
    result.status !== 200 ||
    JSON.stringify(await result.json()) !==
      JSON.stringify(stoppedSQL.wire.reply) ||
    calls !== 2
  ) throw new Error("Actual SQL stop receipt was not preserved");
});
