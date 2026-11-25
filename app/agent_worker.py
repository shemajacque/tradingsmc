import time

from . import ai_agent as agent


def main() -> None:
    while True:
        state = agent.get_state()
        if not state["running"]:
            break
        try:
            agent._tick()
        except Exception:
            pass
        interval = max(5, min(300, int(state["config"].get("interval_sec", 15))))
        time.sleep(interval)


if __name__ == "__main__":
    main()
