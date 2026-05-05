import { useMemo, useState } from "react";
import "./PlanInputPanel.css";

type PlanInputOption = {
  id?: string;
  label?: string;
  description?: string;
};

type PlanInputQuestion = {
  id?: string;
  header?: string;
  question?: string;
  options?: PlanInputOption[];
  allowCustomAnswer?: boolean;
};

type PlanInputRequest = {
  id?: string;
  title?: string;
  questions?: PlanInputQuestion[];
};

type PlanInputPanelProps = {
  request: PlanInputRequest;
  disabled?: boolean;
  onSubmit: (payload: Record<string, unknown>) => Promise<void> | void;
};

export function PlanInputPanel({ request, disabled = false, onSubmit }: PlanInputPanelProps) {
  const questions = useMemo(
    () => (Array.isArray(request?.questions) ? request.questions : []).filter((q) => String(q?.id || "").trim()),
    [request]
  );
  const [selectedByQuestion, setSelectedByQuestion] = useState<Record<string, string>>({});
  const [customByQuestion, setCustomByQuestion] = useState<Record<string, string>>({});
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [errorText, setErrorText] = useState("");

  async function submit(status: "answered" | "cancelled") {
    if (isSubmitting || disabled) return;
    setErrorText("");
    const answers = status === "cancelled"
      ? []
      : questions.map((question) => {
        const questionId = String(question.id || "");
        const custom = String(customByQuestion[questionId] || "").trim();
        const selected = String(selectedByQuestion[questionId] || "").trim();
        return custom
          ? { questionId, customAnswer: custom }
          : { questionId, selectedOptionId: selected };
      });
    if (status === "answered" && answers.some((answer) => !answer.selectedOptionId && !answer.customAnswer)) {
      setErrorText("Answer every question before submitting.");
      return;
    }
    setIsSubmitting(true);
    try {
      await onSubmit({
        status,
        userId: "dashboard",
        answers
      });
    } catch {
      setErrorText("Could not submit answers.");
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <section className="plan-input-panel" aria-label="Plan input request">
      <div className="plan-input-panel__head">
        <span className="material-symbols-rounded" aria-hidden="true">help</span>
        <strong>{request.title || "Input needed"}</strong>
      </div>
      {questions.map((question) => {
        const questionId = String(question.id || "");
        const options = Array.isArray(question.options) ? question.options : [];
        return (
          <div key={questionId} className="plan-input-panel__question">
            {question.header ? <span className="plan-input-panel__header">{question.header}</span> : null}
            <p>{question.question}</p>
            <div className="plan-input-panel__options">
              {options.map((option) => {
                const optionId = String(option.id || "");
                return (
                  <label key={optionId} className="plan-input-panel__option">
                    <input
                      type="radio"
                      name={`plan-input-${request.id}-${questionId}`}
                      checked={selectedByQuestion[questionId] === optionId && !customByQuestion[questionId]}
                      disabled={disabled || isSubmitting}
                      onChange={() => {
                        setSelectedByQuestion((current) => ({ ...current, [questionId]: optionId }));
                        setCustomByQuestion((current) => ({ ...current, [questionId]: "" }));
                      }}
                    />
                    <span>
                      <strong>{option.label || optionId}</strong>
                      {option.description ? <small>{option.description}</small> : null}
                    </span>
                  </label>
                );
              })}
            </div>
            {question.allowCustomAnswer !== false ? (
              <input
                className="plan-input-panel__custom"
                type="text"
                value={customByQuestion[questionId] || ""}
                disabled={disabled || isSubmitting}
                placeholder="Custom answer"
                onChange={(event) => {
                  const value = event.target.value;
                  setCustomByQuestion((current) => ({ ...current, [questionId]: value }));
                  if (value.trim()) {
                    setSelectedByQuestion((current) => ({ ...current, [questionId]: "" }));
                  }
                }}
              />
            ) : null}
          </div>
        );
      })}
      {errorText ? <p className="plan-input-panel__error">{errorText}</p> : null}
      <div className="plan-input-panel__actions">
        <button type="button" className="btn btn-secondary btn-sm" disabled={disabled || isSubmitting} onClick={() => void submit("cancelled")}>
          Cancel
        </button>
        <button type="button" className="btn btn-primary btn-sm" disabled={disabled || isSubmitting} onClick={() => void submit("answered")}>
          Submit
        </button>
      </div>
    </section>
  );
}
