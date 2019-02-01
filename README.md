# asheville_notifications
SQL/PostgreSQL portion of a possible solution for the citizen notification project.


Main entities:
  * Category: Major theme for a notification. Construction projects, bond package, etc.
  * Topic: Topic for subscribers to, well, subscribe to. They include the general
    categories as well as individual specific categoried topics.

  * Vector: a delivery mechanism, such as email. Future could include SMS, POSTAL,
    FAX, and so on.

    Side table vector_mime_type describes what MIME types are required to compose
    for this vector. See message_body_part below ...

  * Subscriber: person who wants notifications. Side table subscriber_vector describes
    the subscriber's address to use for this vector.

  * Subscription: record indicating a person is interested in messages about
    this specific topic delivered through this specific vector. When a subscription
    happens for a general category's topic, then subscriptions for all topics within
    that category are materialized. Full possible-order-of-operations changes to
    these meta-subscriptions are covered through triggers and tested.

  * Message: Something to share with the people. Side table message_body_part
    contains the body of the message, spelled in a given mime-type for the
    use of a given vector. Messages will need to have body parts for all
    (vector, mime_type) pairings described in vector_mime_type. Currently
    configured for emails to have both text/plain and text/html body parts.
    Messages and bodyparts can be composed over multiple transactions, but
    can only be scheduled to be sent (via send_on going not-null) when
    all required parts are present.

  * message_transmission_queue: work queue for keeping track of the transmission
    status of messages cleared to be sent to subscriptions. Populated by stored
    function populate_message_transmission_queue(). Blocks of work units
    checked out via check_out_enqueued_for_transmit().
