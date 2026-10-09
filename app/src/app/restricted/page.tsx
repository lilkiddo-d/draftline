export default function Restricted() {
  return (
    <div className="card" style={{ maxWidth: 560 }}>
      <h1>Not available in your region</h1>
      <p className="muted">
        Draftline&apos;s interface is not available in your jurisdiction. You can still read the{" "}
        <a href="/risk">risk disclosure</a>.
      </p>
    </div>
  );
}
