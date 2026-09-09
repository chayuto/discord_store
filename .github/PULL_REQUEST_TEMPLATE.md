## What this changes

<!-- One paragraph. What was wrong or missing, and what you did about it. -->

## Why

<!-- This library exists partly to argue for a set of design decisions, so the
     reasoning matters as much as the diff. If you changed a decision, say which
     one and what changed your mind. -->

## Checklist

- [ ] `bundle exec rake` passes (tests and RuboCop)
- [ ] `bundle exec appraisal rake` passes, if the change touches Rails integration
- [ ] New Discord behaviour is modelled in `Transport::Fake` before being relied on
- [ ] `test/support/shared_service_tests.rb` is unedited
- [ ] The Terms of Service guard and `own_messages_only` are untouched, or the
      change explains at length why they should not be
- [ ] CHANGELOG.md updated
