CREATE TABLE users (
  id         UUID NOT NULL PRIMARY KEY,
  name       TEXT NOT NULL,
  foreign_id TEXT
);

CREATE TABLE posts (
  id      UUID NOT NULL PRIMARY KEY,
  author  UIUD NOT NULL,
  title   TEXT NOT NULL,
  body    TEXT NOT NULL,
  parent  UUID,

  FOREIGN KEY(author) REFERENCES users(id)
);
