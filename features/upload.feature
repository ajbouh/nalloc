Feature: upload
  In order to do useful multi-node development
  As a developer
  I want to be able to upload files to allocated nodes

  Scenario: upload random file to remote
    Given I know the cluster platform
    And I have the following nodes allocated
      | Name    |
      | web     |

    # Test nalloc's raw upload functionality
    When I generate a new random value
    And I create a temporary file with that random value
    And I upload that file to "/tmp" on "web"
    And I examine that file on "web"
    Then I should see that random value
    Then I destroy it
