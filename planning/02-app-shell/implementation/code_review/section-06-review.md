# Code Review: Section 06 - Route picker

Evaluation order, choice and override semantics match the plan; no route-choice bugs. Findings:

1. Other engines' native routes were ordered ahead of Wine in `candidates`.
2. Ordering reasons (`fexPreferredWithJIT`, `nativeFirst`) were added to unavailable candidates and could leak into override warnings.
3. `RouteRules` couldn't express gates for native routes or architecture-independent gates.
4. The rules table was a dictionary: no exhaustiveness; dead fallback with a wrong verdict; `nativeRoute` relied on dictionary order.
5. On override, `chosen` carried `overriddenByUser` but its entry in `candidates` didn't.
6. Test gap: a planned route with a declined runtime check.
