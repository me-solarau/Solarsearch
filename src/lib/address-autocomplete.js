import { loadGooglePlaces } from "./places.js";

function parseAddressComponents(components = []) {
  const long = (type) => components.find((c) => c.types.includes(type))?.long_name ?? null;
  const short = (type) => components.find((c) => c.types.includes(type))?.short_name ?? null;
  return {
    streetNumber: long("street_number"),
    route: long("route"),
    suburb: long("locality") || long("sublocality") || null,
    state: short("administrative_area_level_1"),
    postcode: long("postal_code"),
    country: short("country"),
  };
}

// Binds Google Places Autocomplete to an <input>, restricted to AU street
// addresses. Sets the input's value + fires input/change events on selection
// so any existing listener on that field keeps working unchanged.
// onPlaceSelected(details) is optional — details also carries lat/lng/postcode/etc.
export async function attachAddressAutocomplete(input, { onPlaceSelected, country = "au" } = {}) {
  if (!input) return null;

  let places;
  try {
    places = await loadGooglePlaces();
  } catch (err) {
    console.warn("Address autocomplete unavailable:", err.message);
    return null;
  }
  if (!places) return null;

  const autocomplete = new places.Autocomplete(input, {
    componentRestrictions: { country },
    fields: ["formatted_address", "address_components", "geometry", "place_id"],
    types: ["address"],
  });

  autocomplete.addListener("place_changed", () => {
    const place = autocomplete.getPlace();
    if (!place || !place.geometry) return; // Enter pressed without picking a suggestion

    if (place.formatted_address) input.value = place.formatted_address;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));

    if (onPlaceSelected) {
      onPlaceSelected({
        formattedAddress: place.formatted_address || input.value,
        placeId: place.place_id ?? null,
        lat: place.geometry.location?.lat() ?? null,
        lng: place.geometry.location?.lng() ?? null,
        ...parseAddressComponents(place.address_components),
      });
    }
  });

  return autocomplete;
}
