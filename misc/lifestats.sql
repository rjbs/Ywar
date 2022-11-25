CREATE TABLE lifestats (
  thing_measured text not null,
  measured_at int not null,
  measured_value text not null,
  goal_completed boolean not null
);

CREATE INDEX last_state_lookup ON LIFESTATS (thing_measured, measured_at);
