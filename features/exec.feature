Feature: exec
  In order to do useful multi-node development
  As a developer
  I want to be able to execute commands on allocated nodes

  Scenario: remote commands on 2 nodes
    Given the nodes:
      | Name    |
      | web     |
      | db      |
    And I know the cluster platform
    And the number of active nodes is 0
    When I allocate the nodes
    Then the layout should be representable as JSON
    And the number of active nodes should be 2
    And the following commands should succeed:
      | Node | Command                       |
      | web  | sh -c 'echo -n web > /tmp/me' |
      | db   | sh -c 'echo -n db > /tmp/me'  |
    And the following commands should succeed:
      | Node | Command     | Output |
      | web  | cat /tmp/me | web    |
      | db   | cat /tmp/me | db     |
    When I destroy it
    Then the number of active nodes should be 0
