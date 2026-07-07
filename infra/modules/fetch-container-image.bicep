// Reads the currently deployed image of an existing container app so that a
// re-provision preserves the azd-deployed image instead of reverting to the
// placeholder. Returns '' when the app does not exist yet (first provision).
param exists bool
param name string

resource existingApp 'Microsoft.App/containerApps@2024-03-01' existing = if (exists) {
  name: name
}

// The ternary guards the access at runtime (existingApp is only referenced when exists is true).
#disable-next-line BCP318
output image string = exists ? existingApp.properties.template.containers[0].image : ''
