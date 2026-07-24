CREATE TABLE IF NOT EXISTS offline_msgs (
    receiver TEXT NOT NULL,
    sender TEXT NOT NULL,
    content TEXT NOT NULL,
    msg_id TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS receipt_queue (
    sender TEXT NOT NULL,
    msg_id TEXT NOT NULL,
    receiver TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_offline_msgs_receiver
    ON offline_msgs(receiver);

CREATE INDEX IF NOT EXISTS idx_receipt_queue_sender
    ON receipt_queue(sender);
