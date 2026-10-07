import { Link } from "react-router";
import { Card, EmptyState } from "../components/ui.tsx";

export const NotFound = () => (
  <Card>
    <EmptyState icon="?" title="Page not found" action={<Link to="/" className="btn-primary">Go to markets</Link>} />
  </Card>
);
