// The in-game half of afterburner (https://github.com/mediocretes/afterburner).
// afterburner pushes this file into the game; you don't need to edit it.
//
// Each Ruby script's stub calls serve(), which connects back to afterburner,
// asks it to run the script, and then makes each ns call the script sends,
// one at a time, until the script ends. The stub claims the script's RAM up
// front with ns.ramOverride, so the calls made here are charged to it like
// any script's.

const RAM_HINT =
  "\n\nafterburner charges a Ruby script for the ns calls it can see in the source: " +
  "ns.name(...), @ns.name(...), or a namespace held in a variable (hacknet = ns.hacknet). " +
  "A call made some other way isn't charged, so the game stops the script when it runs.";

/**
 * @param {NS} ns
 * @param {string} script
 * @param {number} port
 * @param {number} ram  what the stub claimed, so afterburner knows what a hot reload can use
 */
export async function serve(ns, script, port, ram) {
  const socket = await connect(port);
  let exiting = false;
  ns.atExit(() => {
    exiting = true;
    socket.close();
  }, "afterburner");
  const inbox = new Inbox(socket);
  send(socket, { op: "start", script, args: ns.args, pid: ns.pid, ram });

  for (;;) {
    const message = await inbox.next();
    if (message === undefined) {
      // Killed in the game, or afterburner stopped. Either way this script is
      // done; say so without an error dialog for every script that was running.
      if (!exiting) ns.tprint(`WARN: afterburner went away while running ${script}, so it has stopped.`);
      return;
    }
    if (message.op === "exit") return;
    if (message.op === "fail") throw new Error(`${script}: ${message.message}`);
    if (message.op === "costs") {
      send(socket, { op: "costs", costs: measureCosts(ns, message.names) });
      continue;
    }

    let reply;
    try {
      reply = { op: "result", id: message.id, value: await invoke(ns, message.path, message.args) };
    } catch (error) {
      // The game killed this script mid-call (for RAM, or ns.exit): let it die.
      if (exiting) throw describe(error).includes("RAM USAGE ERROR") ? new Error(describe(error) + RAM_HINT) : error;
      reply = { op: "error", id: message.id, message: describe(error) };
    }
    send(socket, reply);
  }
}

/**
 * What the game charges for each function. Some costs depend on the player's
 * progress, which the documentation can't know; getFunctionRamCost is free.
 */
function measureCosts(ns, names) {
  const costs = {};
  for (const name of names) {
    try {
      costs[name] = ns.getFunctionRamCost(name);
    } catch {
      // not a function in this version of the game
    }
  }
  return costs;
}

/** Calls ns.a.b(...args), or reads it if it isn't a function. */
async function invoke(ns, path, args) {
  let target = ns;
  for (const key of path.slice(0, -1)) target = target[key];
  const member = target[path[path.length - 1]];
  return typeof member === "function" ? await member.apply(target, args) : member;
}

function connect(port) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://localhost:${port}/script`);
    socket.onopen = () => {
      socket.onerror = null;
      resolve(socket);
    };
    socket.onerror = () =>
      reject(
        new Error(
          `Couldn't reach afterburner on port ${port}. Is \`afterburner watch\` running? ` +
            "In Chrome, the game also needs permission to access the local network.",
        ),
      );
  });
}

/** Messages from afterburner, in order; undefined once the socket closes. */
class Inbox {
  constructor(socket) {
    this.queue = [];
    this.waiting = undefined;
    this.closed = false;
    socket.onmessage = (event) => this.deliver(decode(String(event.data)));
    socket.onclose = () => {
      this.closed = true;
      this.wake(undefined);
    };
  }

  next() {
    const message = this.queue.shift();
    if (message !== undefined || this.closed) return Promise.resolve(message);
    return new Promise((resolve) => (this.waiting = resolve));
  }

  deliver(message) {
    if (this.waiting) this.wake(message);
    else this.queue.push(message);
  }

  wake(message) {
    const waiting = this.waiting;
    this.waiting = undefined;
    waiting?.(message);
  }
}

function send(socket, message) {
  if (socket.readyState !== WebSocket.OPEN) return;
  let text;
  try {
    text = encode(message);
  } catch (error) {
    // e.g. a result with a cycle in it: report it to Ruby instead of dying here.
    if (message.op !== "result") throw error;
    text = encode({ op: "error", id: message.id, message: `The result couldn't be sent to Ruby: ${describe(error)}` });
  }
  socket.send(text);
}

// JSON can't carry Infinity or NaN, which some ns functions return, so both
// sides tag them as {"$num": "Infinity"}.
function encode(value) {
  return JSON.stringify(value, (_key, v) => (typeof v === "number" && !Number.isFinite(v) ? { $num: String(v) } : v));
}

function decode(text) {
  return JSON.parse(text, (_key, v) =>
    v !== null && typeof v === "object" && !Array.isArray(v) && Object.keys(v).length === 1 && typeof v.$num === "string"
      ? Number(v.$num)
      : v,
  );
}

function describe(error) {
  return error instanceof Error ? error.message : String(error);
}
