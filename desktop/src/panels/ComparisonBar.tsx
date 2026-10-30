// Comparing, over the canvas, as the Mac's: which side to show (then, the changes, or now; before and after, for a
// review), what's changed, and Done, or End Review for the review open now, which keeps its change in the history.
import { useEffect } from "preact/hooks";
import { core } from "../core.ts";
import { act, set, useStore } from "../store.ts";
import { when } from "./History.tsx";

export function ComparisonBar() {
  const { scene, preview } = useStore();
  const comparing = !!scene?.comparing;
  const reviewVersion = !!preview?.isReview;
  const isReview = !preview || reviewVersion;
  const endsReview = !preview && !!scene?.reviewing;

  function done() {
    if (endsReview) {
      act(() => core.endReview());
    } else {
      act(() => core.endPreview());
      set({ preview: null });
    }
  }

  // Escape is Done, for a version; a review only ends from its button.
  useEffect(() => {
    if (!comparing || endsReview) return;
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !(e.target instanceof HTMLInputElement)) done();
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [comparing, endsReview, preview?.file]);

  if (!scene || !comparing) return null;
  const side = scene.side;
  const summary = scene.summary ?? "No changes";
  let caption: string;
  if (preview && reviewVersion) {
    caption = side === "changes" ? `Reviewed ${when(preview.date)}: ${summary}`
      : `${side === "then" ? "Before" : "After"} the change reviewed ${when(preview.date)}, read-only`;
  } else if (preview) {
    caption = side === "changes" ? `${when(preview.date)} to now: ${summary}` : `${side === "then" ? when(preview.date) : "Now"}, read-only`;
  } else {
    caption = side === "changes" ? `Review: ${summary}` : `${side === "then" ? "Before" : "After"} the change, read-only`;
  }
  const titles = { then: isReview ? "Before" : "Then", changes: "Changes", now: isReview ? "After" : "Now" } as const;

  return (
    <div class="comparison-bar" role="toolbar" aria-label="Comparing">
      <span aria-hidden="true">{isReview ? "±" : "⟲"}</span>
      <div class="segmented" role="radiogroup" aria-label="Show">
        {(["then", "changes", "now"] as const).map((s) => (
          <button key={s} role="radio" aria-checked={side === s} class={side === s ? "on" : ""} onClick={() => act(() => core.setComparisonSide(s))}>
            {titles[s]}
          </button>
        ))}
      </div>
      <span class="caption">{caption}</span>
      {endsReview ? (
        <button onClick={done} title="Stop comparing: keep the data model as it is after the change, to edit. The change stays in the version history, to look at again">
          End Review
        </button>
      ) : (
        <button onClick={done} title="Back to editing the data model as it is now (Escape)">Done</button>
      )}
    </div>
  );
}
